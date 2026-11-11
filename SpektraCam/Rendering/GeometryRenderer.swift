import CoreGraphics
import CoreImage
import Foundation

/// Reuses the system's GPU-backed image context; never changes the source bitmap.
enum GeometryRenderer {
    nonisolated private static let context = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: NSNull(),
    ])

    nonisolated static func render(_ source: CGImage, geometry: ImageGeometry) -> CGImage? {
        if geometry.isIdentity { return source }
        let image = transformed(CIImage(cgImage: source), geometry: geometry)
        let colorSpace = source.colorSpace?.model == .rgb ? source.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
    }

    /// The same geometry in the linear input path; no intermediate 8-bit bitmap.
    nonisolated static func transformed(_ source: CIImage, geometry: ImageGeometry) -> CIImage {
        var image = source
        if geometry.quarterTurns != 0 {
            // Integer matrices avoid a floating-point extra pixel at 90 degrees.
            let rotation: CGAffineTransform
            switch geometry.quarterTurns % 4 {
            case 1: rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
            case 2: rotation = CGAffineTransform(scaleX: -1, y: -1)
            case 3: rotation = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
            default: rotation = .identity
            }
            image = normalize(image.transformed(by: rotation))
        }
        if geometry.flippedHorizontally {
            image = normalize(image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)))
        }
        if geometry.flippedVertically {
            image = normalize(image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)))
        }
        if geometry.straightenDegrees != 0 {
            let angle = geometry.straightenDegrees * .pi / 180
            let zoom = geometry.constrainedScale(in: image.extent.size)
            let framing = geometry.boundedFraming(in: image.extent.size)
            let c = cos(angle) * zoom
            let s = sin(angle) * zoom
            let x = image.extent.midX
            let y = image.extent.midY
            let transform = CGAffineTransform(
                a: c, b: s, c: -s, d: c,
                tx: x - c * x + s * y + framing.x * image.extent.width,
                ty: y - s * x - c * y - framing.y * image.extent.height)
            let bounds = image.extent
            image = normalize(image.transformed(by: transform).cropped(to: bounds))
        }
        return image
    }

    nonisolated private static func normalize(_ image: CIImage) -> CIImage {
        image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY))
    }
}
