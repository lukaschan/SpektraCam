import CoreGraphics
import CoreImage
import Foundation

@main struct GeometryChecks {
    static func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(
            UnsafeBufferPointer(
                start: context.data!.assumingMemoryBound(to: UInt8.self),
                count: image.width * image.height * 4))
    }
    static func main() {
        let w = 200
        let h = 120
        var data = [UInt8]()
        for y in 0..<h {
            for x in 0..<w {
                data += [UInt8(x), UInt8(y), UInt8((x + y) % 255), 255]
            }
        }
        let cg = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
        for angle in [-45.0, -12, 12, 45] {
            for x in [-0.2, 0.2] {
                for y in [-0.2, 0.2] {
                    let geometry = ImageGeometry(straightenDegrees: angle, framingX: x, framingY: y)
                    let neutral = ImageGeometry(straightenDegrees: angle)
                    precondition(geometry.constrainedScale(in: CGSize(width: w, height: h)) == neutral.constrainedScale(in: CGSize(width: w, height: h)), "Dragging changed straighten zoom")
                    let framed = GeometryRenderer.render(cg, geometry: geometry)!
                    let bytes = pixels(framed)
                    precondition(
                        stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 },
                        "Reframing exposed a transparent border")
                    let saved = try! JSONDecoder().decode(
                        ImageGeometry.self, from: JSONEncoder().encode(geometry))
                    precondition(saved == geometry, "Framing did not survive restart")
                }
            }
        }
        let old = try! JSONDecoder().decode(ImageGeometry.self, from: Data("{\"straightenDegrees\":12}".utf8))
        precondition(old.framingX == 0 && old.framingY == 0)
        var corner = CropSelection()
        corner.aspect = .square
        corner.normalizedRect = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.75)
        let cornerStart = corner.normalizedRect
        corner.resize(
            from: cornerStart, corner: .bottomRight, by: CGSize(width: 0.05, height: 0.075), imageAspect: 1.5)
        precondition(
            abs(corner.normalizedRect.width - 0.55) < 1e-9,
            "Constrained handle diverged from the finger diagonal")
        let baseline = pixels(cg)
        var count = 0
        for q in 0..<4 {
            for fh in [false, true] {
                for fv in [false, true] {
                    let g = ImageGeometry(quarterTurns: q, flippedHorizontally: fh, flippedVertically: fv)
                    let out = GeometryRenderer.render(cg, geometry: g)!
                    precondition(out.width == (q % 2 == 0 ? w : h) && out.height == (q % 2 == 0 ? h : w))
                    var rotated = g
                    rotated.rotateLeft()
                    let direct = GeometryRenderer.render(cg, geometry: rotated)!
                    let repeated = GeometryRenderer.render(out, geometry: ImageGeometry(quarterTurns: 1))!
                    precondition(pixels(direct) == pixels(repeated), "Quarter turn composition")
                    var horizontal = g
                    horizontal.flipHorizontal()
                    let hdirect = GeometryRenderer.render(cg, geometry: horizontal)!
                    let hrepeated = GeometryRenderer.render(
                        out, geometry: ImageGeometry(flippedHorizontally: true))!
                    precondition(pixels(hdirect) == pixels(hrepeated), "Horizontal flip composition")
                    count += 1
                }
            }
        }
        var selection = CropSelection(normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5))
        let before = cg.cropping(to: selection.pixelRect(in: CGSize(width: w, height: h)))!
        selection.rotateLeft(imageAspect: CGFloat(w) / CGFloat(h))
        let whole = GeometryRenderer.render(cg, geometry: ImageGeometry(quarterTurns: 1))!
        let after = whole.cropping(to: selection.pixelRect(in: CGSize(width: h, height: w)))!
        let expected = GeometryRenderer.render(before, geometry: ImageGeometry(quarterTurns: 1))!
        precondition(pixels(after) == pixels(expected), "Crop region rotates with source")
        for angle in [-45.0, -30, -1, 0.1, 1, 30, 45] {
            let g = ImageGeometry(straightenDegrees: angle)
            let out = GeometryRenderer.render(cg, geometry: g)!
            let p = pixels(out)
            precondition(
                stride(from: 3, to: p.count, by: 4).allSatisfy { p[$0] == 255 },
                "Transparent rotation corner at \(angle)")
            precondition(out.width == w && out.height == h)
            let zoom = g.constrainedScale(in: CGSize(width: w, height: h))
            let radians = angle * .pi / 180
            for x in [-Double(w) / 2, Double(w) / 2] {
                for y in [-Double(h) / 2, Double(h) / 2] {
                    let ix = (cos(radians) * x + sin(radians) * y) / zoom
                    let iy = (-sin(radians) * x + cos(radians) * y) / zoom
                    precondition(abs(ix) < Double(w) / 2 && abs(iy) < Double(h) / 2)
                }
            }
            count += 1
        }
        // A zoomed region is rendered from its source rectangle and then turned on its own.
        for turns in 0..<4 { for flipH in [false, true] { for flipV in [false, true] {
            let geometry = ImageGeometry(quarterTurns: turns, flippedHorizontally: flipH, flippedVertically: flipV)
            let full = GeometryRenderer.render(cg, geometry: geometry)!
            let ow = full.width, oh = full.height
            let shown = CGRect(x: 30, y: 20, width: 50, height: 40)
            let unit = CGRect(x: shown.minX / Double(ow), y: shown.minY / Double(oh), width: shown.width / Double(ow), height: shown.height / Double(oh))
            let source = geometry.sourceRect(forOriented: unit)
            let rect = CGRect(x: (source.minX * Double(w)).rounded(), y: (source.minY * Double(h)).rounded(),
                              width: (source.width * Double(w)).rounded(), height: (source.height * Double(h)).rounded())
            let part = GeometryRenderer.render(cg.cropping(to: rect)!, geometry: geometry.orientationOnly)!
            precondition(pixels(part) == pixels(full.cropping(to: shown)!), "Region mapping differs for \(turns) \(flipH) \(flipV)")
            let back = geometry.orientedRect(forSource: source)
            precondition(abs(back.minX - unit.minX) < 1e-9 && abs(back.minY - unit.minY) < 1e-9 && abs(back.width - unit.width) < 1e-9)
            count += 1
        } } }
        precondition(pixels(cg) == baseline)
        precondition(CropSelection().aspect == .original)
        print(
            "PASS: \(count) image geometry configurations; exact dimensions, transform composition, ROI rotation, opaque constrained corners and source preservation"
        )
    }
}
