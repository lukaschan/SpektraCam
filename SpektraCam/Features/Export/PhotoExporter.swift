import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
                    localized: "photo_exporter.the_original_photo_could_not_be_decoded",
                    defaultValue: "The original photo could not be decoded.")
            case .render:
                String(
                    localized: "photo_exporter.the_full_resolution_image_could_not_be",
                    defaultValue: "The full-resolution image could not be rendered.")
            case .encode:
                String(
                    localized: "photo_exporter.the_export_file_could_not_be_created",
                    defaultValue: "The export file could not be created.")
            }
        }
    }
    enum Size: String, CaseIterable, Identifiable, Sendable {
        case full = "Full", large = "L", medium = "M", small = "S"
        var title: String {
            switch self {
            case .full: String(localized: "export.size.full", defaultValue: "Full")
            case .large: String(localized: "export.size.large", defaultValue: "L")
            case .medium: String(localized: "export.size.medium", defaultValue: "M")
            case .small: String(localized: "export.size.small", defaultValue: "S")
            }
        }
        var id: Self { self }
        var maximum: Int? {
            switch self {
            case .full: nil
            case .large: 4096
            case .medium: 2048
            case .small: 1080
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
            let scale = min(
                1, Double(size.maximum ?? Int.max) / max(dimensions.width, dimensions.height))
            try PhotoSource.checkDevelopmentMemory(
                width: max(1, Int(ceil(dimensions.width * scale))),
                height: max(1, Int(ceil(dimensions.height * scale))))
            image = try PhotoExporter.renderOriginal(
                data, crop: CropSelection(), geometry: ImageGeometry(), maximum: size.maximum,
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
