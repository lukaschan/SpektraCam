import CoreGraphics
import CoreImage
import Foundation

/// Shared by editor previews and every export caller. The paper/table never enter this stage.
nonisolated enum FilmEdgeRenderer {
    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let context = CIContext(options: [.workingColorSpace: linear,
        .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])

    /// Manual families use compatible material defaults only for the edge. Develop is preserved.
    static func materialRecipe(_ original: EditRecipe) -> EditRecipe {
        var recipe = original
        recipe.tone.monochrome = false
        recipe.look.enabled = true
        recipe.look.mode = .spektrafilm
        recipe.mix = 1
        let positive = FilmStock.films.first { $0.id == recipe.filmID }?.isPositive == true
        let cinema = FilmStock.prints.first { $0.id == recipe.printID }?.support == "film"
        switch original.resolvedFilmEdgeType {
        case .negativePrint:
            if positive { recipe.filmID = "fujifilm_c200" }
            if cinema { recipe.printID = "fujifilm_crystal_archive_typeii" }
            recipe.scanFilm = false
        case .negativeScan:
            if positive { recipe.filmID = "fujifilm_c200" }
            recipe.scanFilm = true
        case .reversalScan:
            if !positive { recipe.filmID = "fujifilm_provia_100f" }
            recipe.scanFilm = true
        case .cinemaPrint:
            if positive { recipe.filmID = "fujifilm_c200" }
            if !cinema { recipe.printID = "kodak_2383" }
            recipe.scanFilm = false
        }
        return recipe
    }

    /// Extend the scene at the boundary for lens convolution, then gate it in exposure space.
    /// It does not claim to recover the original scene outside an imported photograph.
    /// The scene is sampled in film coordinates, so a tilted strip carries its picture with it.
    static func padded(_ input: SourceImageRenderer.Input, geometry: FilmEdgeGeometry) throws -> [SIMD4<Float>] {
        var pixels = Array(repeating: SIMD4<Float>.zero, count: geometry.width * geometry.height)
        let mm = geometry.millimetersPerPixel
        let cx = Double(geometry.width) / 2, cy = Double(geometry.height) / 2
        for y in 0..<geometry.height {
            if y % 32 == 0 { try Task.checkCancellation() }
            for x in 0..<geometry.width {
                let (fx, fy) = geometry.film(Double(x) + 0.5, Double(y) + 0.5)
                let px = cx + fx / mm, py = cy + fy / mm
                let sx = min(max((px - geometry.gate.minX) / geometry.gate.width * Double(input.width) - 0.5, 0), Double(input.width - 1))
                let sy = min(max((py - geometry.gate.minY) / geometry.gate.height * Double(input.height) - 0.5, 0), Double(input.height - 1))
                let x0 = Int(sx), x1 = min(x0 + 1, input.width - 1), fx0 = Float(sx - Double(x0))
                let y0 = Int(sy), y1 = min(y0 + 1, input.height - 1), fy0 = Float(sy - Double(y0))
                let a = input.pixels[y0 * input.width + x0] * (1 - fx0) + input.pixels[y0 * input.width + x1] * fx0
                let b = input.pixels[y1 * input.width + x0] * (1 - fx0) + input.pixels[y1 * input.width + x1] * fx0
                pixels[y * geometry.width + x] = a * (1 - fy0) + b * fy0
            }
        }
        return pixels
    }

    /// Creative cross-family / LUT / partial-Mix choices keep the developed center untouched.
    /// Matched Auto uses the single full-support graph and does not need this composition.
    /// The centre follows the strip's tilt and is blended through the same soft, worn gate.
    /// Dust and scratches are then laid over the centre with the polarity of the chosen route.
    static func replacingCenter(_ edge: CGImage, with center: CGImage, geometry: FilmEdgeGeometry,
                                paperPrint: Bool = true) throws -> CGImage {
        let rect = geometry.gate
        let gate = CGRect(x: rect.minX, y: Double(geometry.height) - rect.maxY, width: rect.width, height: rect.height)
        let angle = geometry.distress.tilt * .pi / 180
        let mid = CGPoint(x: Double(geometry.width) / 2, y: Double(geometry.height) / 2)
        let photograph = CIImage(cgImage: center)
            .transformed(by: CGAffineTransform(scaleX: gate.width / Double(center.width), y: gate.height / Double(center.height)))
            .transformed(by: CGAffineTransform(translationX: gate.minX, y: gate.minY))
            .transformed(by: CGAffineTransform(translationX: -mid.x, y: -mid.y)
                .concatenating(CGAffineTransform(rotationAngle: -angle))  // y-up: film turns clockwise for +tilt
                .concatenating(CGAffineTransform(translationX: mid.x, y: mid.y)))
        let canvas = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        let mask = try gateCoverageMap(geometry)
        let result = photograph.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(cgImage: edge), kCIInputMaskImageKey: try gateMask(mask, geometry)])
            .cropped(to: canvas)
        let d = geometry.distress
        guard d.dust > 0 || d.scratches > 0 else {
            guard let image = context.createCGImage(result, from: canvas, format: .RGBAf, colorSpace: linear, deferred: false)
            else { throw PhotoExporter.Failure.render }
            return image
        }
        let w = geometry.width, h = geometry.height
        var pixels = [SIMD4<Float>](repeating: .zero, count: w * h)
        pixels.withUnsafeMutableBytes {
            context.render(result, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: canvas, format: .RGBAf, colorSpace: linear)
        }
        try applyCenterDamage(&pixels, mask: mask, geometry: geometry, paperPrint: paperPrint)
        let data = pixels.withUnsafeBytes { Data($0) }
        let damaged = CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: linear)
        guard let image = context.createCGImage(damaged, from: canvas, format: .RGBAf, colorSpace: linear, deferred: false)
        else { throw PhotoExporter.Failure.render }
        return image
    }

    /// A creative centre has no developed density to modulate, so apply the visible result of the
    /// same particles. Paper from a negative: opaque dust and scatter print light (scatter bluish),
    /// cut dye prints its complement (a shallow yellow-layer cut prints yellow, deeper red, then
    /// black). Transmission scan: dust and scatter darken; cut dye lets its complementary light
    /// through (shallow blue, deeper cyan, then the scanner's white).
    static func applyCenterDamage(_ pixels: inout [SIMD4<Float>], mask: [Float], geometry: FilmEdgeGeometry,
                                  paperPrint: Bool) throws {
        let w = geometry.width, h = geometry.height
        let paperWhite = SIMD3<Float>(repeating: 0.8), scanLight = SIMD3<Float>(repeating: 0.77)
        let sw = FilmEdgeGeometry.scatterWeights, weights = SIMD3<Float>(Float(sw.x), Float(sw.y), Float(sw.z))
        let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 4))
        try pixels.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                for y in (band * h / bands)..<((band + 1) * h / bands) {
                    for x in 0..<w {
                        let g = mask[y * w + x]
                        if g <= 0 { continue }
                        let scratch = geometry.scratchFields(x: x, y: y)
                        let dust = Float(geometry.dustOcclusion(x: x, y: y)) * g
                        let scatter = Float(scratch.scatter) * g * weights
                        let cut = SIMD3<Float>(Float(scratch.removal.x), Float(scratch.removal.y), Float(scratch.removal.z)) * g
                        if dust == 0 && scatter == .zero && cut == .zero { continue }
                        let p = out[y * w + x]
                        var v = SIMD3(p.x, p.y, p.z)
                        if paperPrint {
                            v = v * (1 - dust) + paperWhite * dust
                            v = v + (paperWhite - v) * scatter
                            v = v * (1 - cut)
                        } else {
                            v = v * (1 - dust) * (1 - scatter)
                            v = v + (scanLight - v) * cut
                        }
                        out[y * w + x] = SIMD4(v.x, v.y, v.z, 1)
                    }
                }
            }
            try Task.checkCancellation()
        }
    }

    /// Gate coverage per pixel; only pixels near the aperture boundary evaluate the edge.
    static func gateCoverageMap(_ geometry: FilmEdgeGeometry) throws -> [Float] {
        let w = geometry.width, h = geometry.height
        var values = [Float](repeating: 0, count: w * h)
        let margin = Int(ceil((geometry.distress.gateWear + geometry.distress.gateSoftness) / geometry.millimetersPerPixel)) + 3
        let tilt = Int(ceil(abs(sin(geometry.distress.tilt * .pi / 180)) * Double(max(w, h)))) + margin
        let inner = geometry.gate.insetBy(dx: Double(tilt), dy: Double(tilt))
        let outer = geometry.gate.insetBy(dx: -Double(tilt), dy: -Double(tilt))
        for y in 0..<h {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in 0..<w {
                let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                values[y * w + x] = inner.contains(p) ? 1 : outer.contains(p) ? Float(geometry.gateCoverage(x: x, y: y)) : 0
            }
        }
        return values
    }
    static func gateMask(_ values: [Float], _ geometry: FilmEdgeGeometry) throws -> CIImage {
        let bytes = values.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        // Like CIImage(cgImage:), the first bitmap row is the top of the canvas.
        return CIImage(bitmapData: Data(bytes), bytesPerRow: geometry.width,
                       size: CGSize(width: geometry.width, height: geometry.height), format: .L8, colorSpace: nil)
    }
}
