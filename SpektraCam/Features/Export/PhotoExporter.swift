import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Exports the stored RAW bytes without decoding, developing, or re-encoding them.
actor OriginalRAWExporter {
    private let source: URL?
    private let data: Data?
    private let filename: String?
    private let type: String?
    private let width: Int, height: Int
    private var folder: URL?

    init(data: Data, filename: String?, type: String?, width: Int, height: Int) {
        source = nil
        self.data = data
        self.filename = filename
        self.type = type
        self.width = width
        self.height = height
    }
    init(source: URL, filename: String?) {
        self.source = source
        data = nil
        self.filename = filename ?? source.lastPathComponent
        type = PhotoSource.typeHint(for: source)
        width = 0
        height = 0
    }
    func export() throws -> (URL, Int, Int) {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RAW-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let originalName = filename.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Original"
            var name = originalName.isEmpty ? "Original" : originalName
            if URL(fileURLWithPath: name).pathExtension.isEmpty {
                name += "." + (type.flatMap { UTType($0)?.preferredFilenameExtension } ?? "dng")
            }
            let output = directory.appendingPathComponent(name)
            if let source {
                try FileManager.default.copyItem(at: source, to: output)
            } else if let data {
                try data.write(to: output, options: .atomic)
            } else { throw PhotoExporter.Failure.render }
            try Task.checkCancellation()
            if let folder { try? FileManager.default.removeItem(at: folder) }
            folder = directory
            return (output, width, height)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    func discard() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }
}

/// Full-resolution SDR geometry export. Film processing must supply its own renderer.
nonisolated enum PhotoExporter {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case jpeg = "JPEG", png = "PNG"
        var id: Self { self }
        var type: UTType { self == .jpeg ? .jpeg : .png }
        var suffix: String { self == .jpeg ? "jpg" : "png" }
    }
    enum Failure: LocalizedError {
        case decode, render, encode
        var errorDescription: String? {
            switch self {
            case .decode:
                String(
                    localized: "export.error.decode",
                    defaultValue: "The original photo could not be decoded.")
            case .render:
                String(
                    localized: "export.error.render",
                    defaultValue: "The full-resolution image could not be rendered.")
            case .encode:
                String(
                    localized: "export.error.file",
                    defaultValue: "The export file could not be created.")
            }
        }
    }
    /// Output size, as in professional editors: resolved against the picture's native size
    /// (crop, film edge and paper at one source pixel per output pixel) and never enlarged.
    enum Size: Hashable, Sendable, RawRepresentable {
        /// Every native pixel of what is shown. On paper the picture keeps its own resolution.
        case original
        /// Long edge in pixels.
        case longEdge(Int)
        /// Percentage of the native size.
        case percent(Int)
        /// A paper layout at this many pixels per inch of the sheet.
        case print(ppi: Int)
        static let full = Self.original, large = Self.longEdge(4096), medium = Self.longEdge(2048), small = Self.longEdge(1080)
        static let longEdgePresets = [1080, 2048, 3000, 4096, 6000]
        static let percentPresets = [25, 50, 75]
        static let ppiPresets = [240, 300, 360]

        /// The longest output edge for a picture whose native long edge is `native`; nil keeps
        /// it native. `paperLongInches` is the sheet's long side for `.print`, if there is one.
        func longEdge(native: Int, paperLongInches: Double? = nil) -> Int? {
            let target: Int?
            switch self {
            case .original: target = nil
            case .longEdge(let pixels): target = pixels
            case .percent(let percent): target = Int((Double(native) * Double(percent) / 100).rounded())
            case .print(let ppi): target = paperLongInches.map { Int(($0 * Double(ppi)).rounded()) }
            }
            guard let target, target > 0, target < native else { return nil }
            return target
        }
        /// A fixed cap that does not depend on the picture (`.longEdge` only).
        var maximum: Int? {
            if case .longEdge(let pixels) = self { return pixels }
            return nil
        }
        var rawValue: String {
            switch self {
            case .original: "original"
            case .longEdge(let pixels): "long:\(pixels)"
            case .percent(let percent): "percent:\(percent)"
            case .print(let ppi): "print:\(ppi)"
            }
        }
        init?(rawValue: String) {
            let parts = rawValue.split(separator: ":")
            let value = parts.count == 2 ? Int(parts[1]) : nil
            switch (parts.first, value) {
            case ("original", _): self = .original
            case ("long", let v?) where (64...65_536).contains(v): self = .longEdge(v)
            case ("percent", let v?) where (1...100).contains(v): self = .percent(v)
            case ("print", let v?) where (72...1200).contains(v): self = .print(ppi: v)
            default: return nil
            }
        }
    }
    static func sourceDimensions(_ data: Data, sourceType: String? = nil) throws -> CGSize {
        guard let info = PhotoSource.describe(data, typeHint: sourceType) else {
            throw Failure.decode
        }
        return CGSize(width: info.width, height: info.height)
    }
    static func decodeSource(_ data: Data, maximum: Int? = nil, sourceType: String? = nil) throws
        -> CGImage
    {
        guard let info = PhotoSource.describe(data, typeHint: sourceType),
            let image = PhotoSource.preview(
                data, description: info,
                maximum: maximum ?? max(info.width, info.height))
        else { throw Failure.decode }
        return image
    }
    static func renderOriginal(
        _ data: Data, crop: CropSelection, geometry: ImageGeometry, maximum: Int? = nil,
        sourceType: String? = nil
    ) throws -> CGImage {
        let upright = try decodeSource(data, maximum: maximum, sourceType: sourceType)
        // Export has an explicit SDR sRGB contract; source bytes remain untouched.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: upright.width, height: upright.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.render }
        context.draw(upright, in: CGRect(x: 0, y: 0, width: upright.width, height: upright.height))
        guard let bitmap = context.makeImage(),
            let transformed = GeometryRenderer.render(bitmap, geometry: geometry),
            let result = transformed.cropping(
                to: crop.pixelRect(in: CGSize(width: transformed.width, height: transformed.height))
            )
        else { throw Failure.render }
        return result
    }
    static func write(
        _ image: CGImage, format: Format, quality: Double = 0.95,
        directory: URL = FileManager.default.temporaryDirectory,
        sourceData: Data? = nil, sourceType: String? = nil, sourceFilename: String? = nil
    ) throws -> URL {
        let outputImage: CGImage
        if image.bitsPerComponent == 8 && image.colorSpace?.name == CGColorSpace.sRGB {
            outputImage = image
        } else {
            let input = PhotoSource.toSDR(CIImage(cgImage: image))
            guard
                let converted = CIContext(options: [.cacheIntermediates: false]).createCGImage(
                    input, from: input.extent, format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            else { throw Failure.render }
            outputImage = converted
        }
        let folder = directory.appending(path: "Spektrafilm-Exports", directoryHint: .isDirectory)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Keep the camera/source name; isolate exports in unique folders to avoid collisions.
        let stem = sourceFilename.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        let url = folder.appendingPathComponent((stem?.isEmpty == false ? stem! : "Image") + "." + format.suffix)
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, format.type.identifier as CFString, 1, nil)
        else { throw Failure.encode }
        var options: [CFString: Any] =
            format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1)] : [:]
        if let sourceData {
            options.merge(PhotoSource.exportProperties(sourceData, typeHint: sourceType)) {
                _, new in new
            }
        }
        options[kCGImagePropertyOrientation] = 1
        options[kCGImagePropertyPixelWidth] = outputImage.width
        options[kCGImagePropertyPixelHeight] = outputImage.height
        CGImageDestinationAddImage(destination, outputImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw Failure.encode
        }
        return url
    }
}

/// Export an untouched library item without applying the editor's default film look.
actor OriginalPhotoExporter {
    private let source: URL
    private let sourceFilename: String?
    private var size: PhotoExporter.Size?
    private var image: CGImage?
    private var output: URL?
    init(source: URL, sourceFilename: String? = nil) {
        self.source = source
        self.sourceFilename = sourceFilename
    }
    func dimensions() throws -> CGSize {
        try PhotoExporter.sourceDimensions(
            Data(contentsOf: source), sourceType: PhotoSource.typeHint(for: source))
    }
    func export(size: PhotoExporter.Size, format: PhotoExporter.Format, quality: Double) throws -> (
        URL, Int, Int
    ) {
        try Task.checkCancellation()
        if self.size != size || image == nil {
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            let dimensions = try PhotoExporter.sourceDimensions(
                data, sourceType: PhotoSource.typeHint(for: source))
            let maximum = size.longEdge(native: Int(max(dimensions.width, dimensions.height)))
            let scale = min(1, Double(maximum ?? Int.max) / max(dimensions.width, dimensions.height))
            try PhotoSource.checkDevelopmentMemory(
                width: max(1, Int(ceil(dimensions.width * scale))),
                height: max(1, Int(ceil(dimensions.height * scale))))
            image = try PhotoExporter.renderOriginal(
                data, crop: CropSelection(), geometry: ImageGeometry(), maximum: maximum,
                sourceType: PhotoSource.typeHint(for: source))
            self.size = size
        }
        try Task.checkCancellation()
        guard let image else { throw PhotoExporter.Failure.render }
        let url = try PhotoExporter.write(
            image, format: format, quality: quality,
            sourceData: Data(contentsOf: source, options: .mappedIfSafe),
            sourceType: PhotoSource.typeHint(for: source), sourceFilename: sourceFilename)
        self.image = nil
        if let output { try? FileManager.default.removeItem(at: output) }
        output = url
        return (url, image.width, image.height)
    }
    func discard() {
        image = nil
        size = nil
        if let output { try? FileManager.default.removeItem(at: output) }
        output = nil
    }
}
