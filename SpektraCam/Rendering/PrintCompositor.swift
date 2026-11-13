import CoreGraphics
import Foundation

/// A bounded SDR finishing pass. The light table and its shadows never enter the file.
nonisolated enum PrintCompositor {
    /// The print's unexposed margin, read from its corner: paper around a hand print is the
    /// same sheet, not a brighter white.
    static func paperTone(of image: CGImage) -> CGColor {
        var pixel = [UInt8](repeating: 255, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                   space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
           let corner = image.cropping(to: CGRect(x: 0, y: 0, width: 2, height: 2)) {
            context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return CGColor(colorSpace: space, components: [CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255, 1])!
    }
    static func render(_ image: CGImage, layout: PrintLayout, maximum: Int? = nil, paper: CGColor? = nil) throws -> CGImage {
        try Task.checkCancellation()
        let sourceLong = max(image.width, image.height)
        let longEdge = min(sourceLong, maximum ?? sourceLong)
        guard longEdge > 0,
            let geometry = PrintGeometry(
                imageSize: CGSize(width: image.width, height: image.height),
                layout: layout, longEdge: CGFloat(longEdge)),
            geometry.paperSize.width <= 65536, geometry.paperSize.height <= 65536
        else { throw PhotoExporter.Failure.render }
        // Reserve the final RGBA8 canvas and a possible makeImage copy before allocating.
        try ImageMemoryAllowance.check(
            estimate: UInt64(geometry.paperSize.width) * UInt64(geometry.paperSize.height) * 8 + 16 * 1024 * 1024)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: Int(geometry.paperSize.width), height: Int(geometry.paperSize.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw PhotoExporter.Failure.render }
        context.setFillColor(paper ?? CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: geometry.paperSize))
        context.interpolationQuality = .high
        // Centered placement is symmetric under CGContext's vertical coordinate convention.
        context.draw(image, in: geometry.imageRect)
        try Task.checkCancellation()
        guard let output = context.makeImage() else { throw PhotoExporter.Failure.render }
        return output
    }
}
