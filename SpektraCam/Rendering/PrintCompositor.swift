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
    /// The sheet at one source pixel per output pixel of the picture: a small picture on a large
    /// sheet makes a large file, and a picture cropped by the sheet keeps only the pixels shown.
    static func nativeSize(imageSize: CGSize, layout: PrintLayout, content: PrintGeometry.Content = .picture) -> CGSize {
        // A fine reference sheet, so the integer canvas's rounding cannot shift the result by a pixel.
        guard let reference = PrintGeometry(imageSize: imageSize, layout: layout, longEdge: 1_000_000, content: content) else { return imageSize }
        let factor = max(imageSize.width, imageSize.height) / max(reference.imageRect.width, reference.imageRect.height, 1)
        return CGSize(width: (reference.paperSize.width * factor).rounded(), height: (reference.paperSize.height * factor).rounded())
    }
    /// A clean print with a border is masked by the easel blades (`Easel.mask`); a film-edge
    /// enlarger canvas carries its own blades, and the sheet around it continues its paper.
    static func render(_ image: CGImage, layout: PrintLayout, maximum: Int? = nil, paper: CGColor? = nil,
                       content: PrintGeometry.Content = .picture) throws -> CGImage {
        try Task.checkCancellation()
        let native = nativeSize(imageSize: CGSize(width: image.width, height: image.height), layout: layout, content: content)
        let nativeLong = Int(max(native.width, native.height))
        let longEdge = min(nativeLong, maximum ?? nativeLong)
        guard longEdge > 0,
            let geometry = PrintGeometry(
                imageSize: CGSize(width: image.width, height: image.height),
                layout: layout, longEdge: CGFloat(longEdge), content: content),
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
        let sheet = paper ?? CGColor(gray: 1, alpha: 1)
        context.setFillColor(sheet)
        context.fill(CGRect(origin: .zero, size: geometry.paperSize))
        context.interpolationQuality = .high
        // PrintGeometry is top-left; CGContext is bottom-left.
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: geometry.paperSize.height - rect.maxY, width: rect.width, height: rect.height)
        }
        let placed = flipped(geometry.imageRect)
        if geometry.magnification > 0,
           let mask = Easel.mask(width: Int(placed.width.rounded()), height: Int(placed.height.rounded()),
                                 magnification: geometry.magnification, kind: layout.blade, seed: layout.easelSeed) {
            // The blades' penumbra and worn edges: the picture fades to the paper beneath them.
            context.saveGState(); context.clip(to: placed, mask: mask)
            context.draw(image, in: placed)
            context.restoreGState()
        } else {
            context.draw(image, in: placed)
        }
        try Task.checkCancellation()
        guard let output = context.makeImage() else { throw PhotoExporter.Failure.render }
        return output
    }
}
