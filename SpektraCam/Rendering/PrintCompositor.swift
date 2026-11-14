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
    static func nativeSize(imageSize: CGSize, layout: PrintLayout) -> CGSize {
        guard let reference = PrintGeometry(imageSize: imageSize, layout: layout, longEdge: 1000) else { return imageSize }
        let factor = max(imageSize.width, imageSize.height) / max(reference.imageRect.width, reference.imageRect.height, 1)
        return CGSize(width: (reference.paperSize.width * factor).rounded(), height: (reference.paperSize.height * factor).rounded())
    }
    /// `bladeEdge` softens the picture's boundary with the easel blade's penumbra: a clean print,
    /// where the blades cut into the projected picture. A film-edge canvas carries its own easel.
    static func render(_ image: CGImage, layout: PrintLayout, maximum: Int? = nil, paper: CGColor? = nil,
                       bladeEdge: Bool = false) throws -> CGImage {
        try Task.checkCancellation()
        let native = nativeSize(imageSize: CGSize(width: image.width, height: image.height), layout: layout)
        let nativeLong = Int(max(native.width, native.height))
        let longEdge = min(nativeLong, maximum ?? nativeLong)
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
        let sheet = paper ?? CGColor(gray: 1, alpha: 1)
        context.setFillColor(sheet)
        context.fill(CGRect(origin: .zero, size: geometry.paperSize))
        context.interpolationQuality = .high
        // PrintGeometry is top-left; CGContext is bottom-left.
        let rect = geometry.imageRect
        let placed = CGRect(x: rect.minX, y: geometry.paperSize.height - rect.maxY, width: rect.width, height: rect.height)
        context.draw(image, in: placed)
        if bladeEdge { blade(context, rect: placed, width: geometry.bladeBlur, paper: sheet) }
        try Task.checkCancellation()
        guard let output = context.makeImage() else { throw PhotoExporter.Failure.render }
        return output
    }
    /// Paper returns across each blade's penumbra (a disc-shaped pupil's ramp, `width` wide, inside
    /// the opening). Overlapping bands at a corner multiply, as a rectangular aperture does.
    static func blade(_ context: CGContext, rect: CGRect, width: CGFloat, paper: CGColor) {
        guard width > 0.35, rect.width > 2 * width, rect.height > 2 * width else { return }
        let r = Double(width) / 2, steps = 9
        let locations = (0..<steps).map { CGFloat($0) / CGFloat(steps - 1) }
        let colors = locations.map { t in
            paper.copy(alpha: CGFloat(1 - FilmEdgeNoise.penumbra(r - Double(t) * 2 * r, r)))!
        }
        guard let ramp = CGGradient(colorsSpace: paper.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                    colors: colors as CFArray, locations: locations) else { return }
        let w = width
        let sides: [(CGRect, CGPoint, CGPoint)] = [
            (CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height), CGPoint(x: rect.minX, y: 0), CGPoint(x: rect.minX + w, y: 0)),
            (CGRect(x: rect.maxX - w, y: rect.minY, width: w, height: rect.height), CGPoint(x: rect.maxX, y: 0), CGPoint(x: rect.maxX - w, y: 0)),
            (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: w), CGPoint(x: 0, y: rect.minY), CGPoint(x: 0, y: rect.minY + w)),
            (CGRect(x: rect.minX, y: rect.maxY - w, width: rect.width, height: w), CGPoint(x: 0, y: rect.maxY), CGPoint(x: 0, y: rect.maxY - w)),
        ]
        for (band, start, end) in sides {
            context.saveGState(); context.clip(to: band)
            context.drawLinearGradient(ramp, start: start, end: end, options: [])
            context.restoreGState()
        }
    }
}
