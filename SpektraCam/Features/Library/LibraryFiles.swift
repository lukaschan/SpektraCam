import CoreGraphics
import CoreImage
import CoreTransferable
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Own the transfer file until the app has copied it into its library.
nonisolated final class LibraryImportFile: Transferable, Sendable {
    let url: URL
    private let temporaryDirectory: URL
    convenience init(received: ReceivedTransferredFile) throws {
        try self.init(copying: received.file)
    }
    init(copying file: URL) throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)
        url = temporaryDirectory.appendingPathComponent(file.lastPathComponent)
        do { try FileManager.default.copyItem(at: file, to: url) } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
    }
    deinit { try? FileManager.default.removeItem(at: temporaryDirectory) }
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .rawImage) { try LibraryImportFile(received: $0) }
        FileRepresentation(importedContentType: .image) { try LibraryImportFile(received: $0) }
    }
}

actor LibraryFiles {
    // One neutral source, shared by viewer/editor. Original bytes use Data's copy-on-write
    // storage; edited JPEG previews are never used as a processing source.
    private var preparedPhoto: (id: UUID, maximum: Int, photo: ImportedPhoto)?
    enum Failure: LocalizedError {
        case image, missing
        var errorDescription: String? {
            switch self {
            case .image:
                String(
                    localized: "library_files.this_image_format_is_not_supported",
                    defaultValue: "This image format is not supported.")
            case .missing:
                String(
                    localized: "library_files.the_original_photo_is_not_available",
                    defaultValue: "The original photo is not available.")
            }
        }
    }
    nonisolated let root: URL
    nonisolated let cache: URL
    init(root: URL, cache: URL, validIDs: Set<UUID>) throws {
        self.root = root
        self.cache = cache
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Originals"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        // A delete stages files before the database commit. Restore an interrupted delete.
        let manager = FileManager.default
        let originals = root.appendingPathComponent("Originals")
        let trash = root.appendingPathComponent("Trash")
        if manager.fileExists(atPath: trash.path) {
            for folder in try manager.contentsOfDirectory(
                at: trash, includingPropertiesForKeys: nil)
            {
                let target = originals.appendingPathComponent(folder.lastPathComponent)
                if let id = UUID(uuidString: folder.lastPathComponent), validIDs.contains(id),
                    !manager.fileExists(atPath: target.path)
                {
                    try manager.moveItem(at: folder, to: target)
                } else {
                    try manager.removeItem(at: folder)
                }
            }
        }
        // Imports become visible only after an index commit. Remove incomplete app copies.
        for folder in try manager.contentsOfDirectory(
            at: originals, includingPropertiesForKeys: nil)
        {
            if folder.lastPathComponent.hasPrefix(".incoming-")
                || UUID(uuidString: folder.lastPathComponent).map({ !validIDs.contains($0) })
                    == true
            {
                try manager.removeItem(at: folder)
            }
        }
    }
    func pendingCaptures() throws -> [URL] { try CameraInbox(root: root).pending() }
    func removeCapture(_ url: URL) throws { try CameraInbox(root: root).remove(url) }
    nonisolated func sourceURL(_ photo: LibraryPhoto) -> URL {
        root.appendingPathComponent("Originals").appendingPathComponent(photo.id.uuidString)
            .appendingPathComponent("original." + photo.fileExtension)
    }
    private func cacheURL(
        _ photo: LibraryPhoto, thumbnail: Bool, maximum: Int = PreviewQuality.libraryMaximum
    ) -> URL {
        // Render changes must rebuild saved previews even when the edit recipe is unchanged.
        let revision = "v11-"
        return cache.appendingPathComponent(photo.id.uuidString)
            .appendingPathComponent(
                revision + photo.renderKey + (thumbnail ? "-thumb.jpg" : "-preview-\(maximum).jpg"))
    }
    func importPhoto(from url: URL, now: Date = Date()) throws -> LibraryPhoto {
        try Task.checkCancellation()
        guard
            let imported = ImportedPhoto.decode(
                try Data(contentsOf: url, options: .mappedIfSafe),
                maximum: ImportedPhoto.thumbnailMaximumPixelSize,
                typeHint: PhotoSource.typeHint(for: url)),
            let type = imported.sourceType
        else { throw Failure.image }
        let metadata = imported.metadata
        let thumbnail = imported.preview
        let uti = UTType(type)
        let ext = uti?.preferredFilenameExtension ?? "image"
        let hash = try Self.digest(url)
        let photo = LibraryPhoto(
            id: UUID(), filename: url.lastPathComponent, fileExtension: ext,
            contentHash: hash, isRAW: uti?.conforms(to: .rawImage) == true,
            importedAt: now, metadata: metadata)
        let folder = sourceURL(photo).deletingLastPathComponent()
        let staging = folder.deletingLastPathComponent().appendingPathComponent(
            ".incoming-" + photo.id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(
                at: url, to: staging.appendingPathComponent("original." + ext))
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: staging, to: folder)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        try? Self.writeJPEG(thumbnail, to: cacheURL(photo, thumbnail: true))
        return photo
    }
    func cachedImage(
        _ photo: LibraryPhoto, thumbnail: Bool, maximum: Int = PreviewQuality.libraryMaximum
    ) -> CGImage? {
        guard
            let source = CGImageSourceCreateWithURL(
                cacheURL(photo, thumbnail: thumbnail, maximum: maximum) as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    func originalImage(
        _ photo: LibraryPhoto, thumbnail: Bool, maximum: Int = PreviewQuality.libraryMaximum
    ) throws -> CGImage {
        let image = try decodedPhoto(
            photo,
            maximum: thumbnail
                ? ImportedPhoto.thumbnailMaximumPixelSize : maximum
        ).preview
        try? Self.writeJPEG(image, to: cacheURL(photo, thumbnail: thumbnail, maximum: maximum))
        return image
    }
    func decodedPhoto(
        _ photo: LibraryPhoto, maximum: Int = PreviewQuality.editorMaximum,
        neutralPreview: CGImage? = nil
    ) throws
        -> ImportedPhoto
    {
        try Task.checkCancellation()
        if let preparedPhoto, preparedPhoto.id == photo.id, preparedPhoto.maximum >= maximum,
            let cached = preparedPhoto.photo.resizedPreview(maximum: maximum)
        { return cached }
        let data = try Data(contentsOf: sourceURL(photo), options: .mappedIfSafe)
        guard
            let result = ImportedPhoto.decode(
                data, maximum: maximum,
                typeHint: PhotoSource.typeHint(for: sourceURL(photo)),
                neutralPreview: photo.hasEdits ? nil : neutralPreview)
        else { throw Failure.image }
        try Task.checkCancellation()
        if maximum >= 720 { preparedPhoto = (photo.id, maximum, result) }
        return result
    }
    func discardPreparedPhoto() { preparedPhoto = nil }
    func lensName(_ photo: LibraryPhoto) -> String? {
        guard
            let source = CGImageSourceCreateWithURL(
                sourceURL(photo) as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return nil }
        return exif[kCGImagePropertyExifLensModel] as? String
    }
    func nativeRAWSize(_ photo: LibraryPhoto) -> CGSize? {
        CIRAWFilter(imageURL: sourceURL(photo))?.nativeSize
    }
    /// A grid rebuild must never replace the independent 1080 px photo preview.
    @discardableResult func storeThumbnail(_ image: CGImage, photo: LibraryPhoto) throws -> CGImage
    {
        let scale = min(
            1,
            Double(ImportedPhoto.thumbnailMaximumPixelSize) / Double(max(image.width, image.height))
        )
        let small: CGImage
        if scale == 1 {
            small = image
        } else {
            let width = max(1, Int(Double(image.width) * scale))
            let height = max(1, Int(Double(image.height) * scale))
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw Failure.image }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let result = context.makeImage() else { throw Failure.image }
            small = result
        }
        try Self.writeJPEG(small, to: cacheURL(photo, thumbnail: true))
        return small
    }
    func storePreview(
        _ image: CGImage, photo: LibraryPhoto, maximum: Int = PreviewQuality.libraryMaximum
    ) throws {
        try Self.writeJPEG(image, to: cacheURL(photo, thumbnail: false, maximum: maximum))
        guard
            let source = CGImageSourceCreateWithURL(
                cacheURL(photo, thumbnail: false, maximum: maximum) as CFURL, nil),
            let small = Self.thumbnail(source, maximum: ImportedPhoto.thumbnailMaximumPixelSize)
        else { throw Failure.image }
        try Self.writeJPEG(small, to: cacheURL(photo, thumbnail: true))
        // Retain one cached recipe per photo. The original can rebuild older frames.
        let keep = Set([
            cacheURL(photo, thumbnail: true), cacheURL(photo, thumbnail: false, maximum: maximum),
        ])
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: cache.appendingPathComponent(photo.id.uuidString), includingPropertiesForKeys: nil)
        {
            for url in entries where !keep.contains(url) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
    func removeFiles(_ photo: LibraryPhoto) throws {
        if preparedPhoto?.id == photo.id { preparedPhoto = nil }
        let folder = sourceURL(photo).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try? FileManager.default.removeItem(at: cache.appendingPathComponent(photo.id.uuidString))
    }
    func stageRemoval(_ photo: LibraryPhoto) throws -> URL {
        if preparedPhoto?.id == photo.id { preparedPhoto = nil }
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let target = trash.appendingPathComponent(photo.id.uuidString)
        let source = sourceURL(photo).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.moveItem(at: source, to: target)
        }
        return target
    }
    func restore(_ staged: URL, photo: LibraryPhoto) throws {
        if FileManager.default.fileExists(atPath: staged.path) {
            try FileManager.default.moveItem(
                at: staged, to: sourceURL(photo).deletingLastPathComponent())
        }
    }
    func finishRemoval(_ staged: URL, photo: LibraryPhoto) {
        try? FileManager.default.removeItem(at: staged)
        try? FileManager.default.removeItem(at: cache.appendingPathComponent(photo.id.uuidString))
    }
    private static func thumbnail(_ source: CGImageSource, maximum: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum,
            ] as CFDictionary)
    }
    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = NSMutableData()
        guard
            let out = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure.image }
        CGImageDestinationAddImage(
            out, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw Failure.image }
        try (data as Data).write(to: url, options: .atomic)
    }
}

/// Captures stay in Application Support until their library index commit succeeds.
nonisolated struct CameraInbox: Sendable {
    let directory: URL
    init(root: URL) { directory = root.appendingPathComponent("CameraInbox", isDirectory: true) }
    func store(_ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("dng")
        try data.write(to: url, options: .atomic)
        return url
    }
    func pending() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "dng" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }
    func remove(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
        else {
            throw LibraryFiles.Failure.missing
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
