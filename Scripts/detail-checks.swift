import CoreGraphics
import Foundation
import ImageIO

/// The zoomed preview's visible region must be the same picture as a full-size export.
@main struct Checks {
    static func bytes(_ image: CGImage) -> [UInt8] {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(
            start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = root.appendingPathComponent("SpektraCam/Resources/ModelData")
        let width = 2400, height = 1600
        let cg = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var state: UInt64 = 99
        func random() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(state >> 40) / CGFloat(1 << 24)
        }
        cg.setFillColor(CGColor(red: 0.3, green: 0.35, blue: 0.4, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<400 {
            cg.setFillColor(CGColor(red: random(), green: random(), blue: random(), alpha: 1))
            cg.fill(CGRect(x: random() * CGFloat(width), y: random() * CGFloat(height), width: 20 + random() * 180, height: 10 + random() * 120))
        }
        let image = cg.makeImage()!
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        for (name, change) in [
            ("default", { (_: inout EditRecipe) in }),
            ("turned, mirrored, cropped", { (r: inout EditRecipe) in
                r.geometry.quarterTurns = 1
                r.geometry.flippedHorizontally = true
                r.crop.normalizedRect = CGRect(x: 0.1, y: 0.15, width: 0.7, height: 0.6)
            }),
            ("diffusion, monochrome", { (r: inout EditRecipe) in
                r.flags["camera.diffusion_filter.active"] = true
                r.tone.monochrome = true
                r.geometry.quarterTurns = 3
            }),
        ] as [(String, (inout EditRecipe) -> Void)] {
            let worker = PhotoRenderer(
                source: image, directory: directory, data: encoded as Data, previewMaximum: 720)
            var recipe = EditRecipe()
            recipe.flags["camera.auto_exposure"] = false
            recipe.flags["film_render.grain.active"] = false
            recipe.flags["print_render.glare.active"] = false
            change(&recipe)
            let export = try await worker.export(recipe, size: .full, format: .png, quality: 1)
            let lazy = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(export.0 as CFURL, nil)!, 0, nil)!
            // Decode before the file goes away.
            let decoded = bytes(lazy)
            let full = CGImage(
                width: lazy.width, height: lazy.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: lazy.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: CGDataProvider(data: Data(decoded) as CFData)!, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)!
            try? FileManager.default.removeItem(at: export.0)
            let visible = CGRect(x: 0.32, y: 0.41, width: 0.3, height: 0.25)
            let started = Date()
            guard let detail = try await worker.renderDetail(recipe, visible: visible, longEdge: max(full.width, full.height))
            else { preconditionFailure("\(name): no detail") }
            let first = Date().timeIntervalSince(started)
            let again = Date()
            _ = try await worker.renderDetail(recipe, visible: visible.offsetBy(dx: 0.1, dy: 0.05), longEdge: max(full.width, full.height))
            let second = Date().timeIntervalSince(again)
            let rect = CGRect(
                x: (detail.rect.minX * Double(full.width)).rounded(), y: (detail.rect.minY * Double(full.height)).rounded(),
                width: Double(detail.image.width), height: Double(detail.image.height))
            precondition(detail.rect.contains(visible.insetBy(dx: 1e-6, dy: 1e-6)), "\(name): region does not cover the view")
            precondition(abs(detail.rect.width * Double(full.width) - Double(detail.image.width)) < 1.5, "\(name): scale \(detail.rect) \(detail.image.width)")
            let a = bytes(detail.image), b = bytes(full.cropping(to: rect)!)
            precondition(a.count == b.count, "\(name): size")
            var maximum = 0, total = 0
            for i in a.indices where i % 4 != 3 { let d = abs(Int(a[i]) - Int(b[i])); maximum = max(maximum, d); total += d }
            print(String(format: "%@: %dx%d of %dx%d, max %d/255, mean %.3f; first %.2fs, pan %.2fs", name, detail.image.width, detail.image.height, full.width, full.height, maximum, Double(total) / Double(a.count * 3 / 4), first, second))
            precondition(maximum <= 3, "\(name): region differs from export by \(maximum)")
            let coarse = try await worker.renderDetail(recipe, visible: visible, longEdge: 300)
            precondition(coarse == nil, "\(name): detail offered when the preview is already sharp")
        }
        print("PASS: zoomed region matches the full export through turns, mirrors, crop, diffusion and monochrome")
    }
}
