import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct ImportedPhoto: Sendable {
    static let thumbnailMaximumPixelSize = 384
    static let previewMaximumPixelSize = 2160

    let data: Data
    let preview: CGImage
    let width: Int
    let height: Int
    let rawTemperature: Double?
    var metadata = PhotoMetadata()
    var sourceType: String? = nil
    var sourceDescription: PhotoSource.Description? = nil

    func resizedPreview(maximum: Int) -> Self? {
        guard let image = PhotoSource.preview(preview, maximum: maximum) else { return nil }
        return .init(
            data: data, preview: image, width: width, height: height,
            rawTemperature: rawTemperature, metadata: metadata,
            sourceType: sourceType, sourceDescription: sourceDescription)
    }

    static func decode(
        _ data: Data, maximum: Int = previewMaximumPixelSize, typeHint: String? = nil,
        neutralPreview: CGImage? = nil
    )
        -> Self?
    {
        guard
            let description = PhotoSource.describe(data, typeHint: typeHint),
            let source = PhotoSource.imageSource(data, typeHint: description.type),
            let preview = neutralPreview.flatMap({ PhotoSource.preview($0, maximum: maximum) })
                ?? PhotoSource.preview(data, description: description, maximum: maximum)
        else { return nil }
        // Materialize ImageIO's lazy provider before UI and renderer share it.
        // A plain bitmap also avoids concurrent lazy-decoder locks on Simulator.
        let space =
            preview.colorSpace?.model == .rgb
            ? preview.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let bitmap = CGContext(
                data: nil, width: preview.width, height: preview.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        bitmap.draw(preview, in: CGRect(x: 0, y: 0, width: preview.width, height: preview.height))
        guard let decodedPreview = bitmap.makeImage() else { return nil }
        var properties = PhotoSource.captureProperties(source, data: data)
        properties[kCGImagePropertyPixelWidth] = description.width
        properties[kCGImagePropertyPixelHeight] = description.height
        return .init(
            data: data, preview: decodedPreview,
            width: properties[kCGImagePropertyPixelWidth] as? Int ?? preview.width,
            height: properties[kCGImagePropertyPixelHeight] as? Int ?? preview.height,
            rawTemperature: description.temperature,
            metadata: PhotoMetadata(
                properties: properties, type: description.type as CFString, image: decodedPreview),
            sourceType: description.type, sourceDescription: description)
    }
}
