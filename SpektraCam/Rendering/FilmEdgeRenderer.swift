import CoreGraphics
import CoreImage
import Foundation
import simd

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
        // An inverted scan makes the same positive as a print; only the frame around it differs.
        case .negativePrint, .invertedScan:
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
    /// A full-size canvas is written to file-backed storage and rendered in tiles.
    /// `region` limits the result to a rectangle of the canvas (for the loupe), always in a store.
    static func padded(
        _ input: SourceImageRenderer.Input, geometry: FilmEdgeGeometry,
        region: (x: Int, y: Int, w: Int, h: Int)? = nil
    ) throws -> SourceImageRenderer.Input {
        let width = region?.w ?? geometry.width, height = region?.h ?? geometry.height
        let left = Double(region?.x ?? 0), top = Double(region?.y ?? 0)
        let store = region != nil || PixelStore.isLarge(width: width, height: height)
            ? try PixelStore(width: width, height: height, format: .float) : nil
        var pixels = Array(repeating: SIMD4<Float>.zero, count: store == nil ? width * height : 0)
        func fill(_ source: UnsafePointer<SIMD4<Float>>, _ target: UnsafeMutablePointer<SIMD4<Float>>) throws {
            let mm = geometry.millimetersPerPixel
            let cx = Double(geometry.width) / 2, cy = Double(geometry.height) / 2
            let bands = max(1, min(height / 32, ProcessInfo.processInfo.activeProcessorCount * 4))
            nonisolated(unsafe) let source = source, target = target
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                for y in (band * height / bands)..<((band + 1) * height / bands) {
                    for x in 0..<width {
                        let (fx, fy) = geometry.film(left + Double(x) + 0.5, top + Double(y) + 0.5)
                        let px = cx + fx / mm, py = cy + fy / mm
                        let sx = min(max((px - geometry.gate.minX) / geometry.gate.width * Double(input.width) - 0.5, 0), Double(input.width - 1))
                        let sy = min(max((py - geometry.gate.minY) / geometry.gate.height * Double(input.height) - 0.5, 0), Double(input.height - 1))
                        let x0 = Int(sx), x1 = min(x0 + 1, input.width - 1), fx0 = Float(sx - Double(x0))
                        let y0 = Int(sy), y1 = min(y0 + 1, input.height - 1), fy0 = Float(sy - Double(y0))
                        let a = source[y0 * input.width + x0] * (1 - fx0) + source[y0 * input.width + x1] * fx0
                        let b = source[y1 * input.width + x0] * (1 - fx0) + source[y1 * input.width + x1] * fx0
                        target[y * width + x] = a * (1 - fy0) + b * fy0
                    }
                }
            }
            try Task.checkCancellation()
        }
        func read(_ body: (UnsafePointer<SIMD4<Float>>) throws -> Void) throws {
            if let source = input.store {
                try body(UnsafePointer(source.base.assumingMemoryBound(to: SIMD4<Float>.self)))
            } else {
                try input.pixels.withUnsafeBufferPointer { try body($0.baseAddress!) }
            }
        }
        if let store {
            try read { try fill($0, store.base.assumingMemoryBound(to: SIMD4<Float>.self)) }
        } else {
            try pixels.withUnsafeMutableBufferPointer { target in
                try read { try fill($0, target.baseAddress!) }
            }
        }
        return .init(pixels: pixels, width: width, height: height, store: store)
    }

    /// Creative cross-family / LUT / partial-Mix choices keep the developed center untouched.
    /// Matched Auto uses the single full-support graph and does not need this composition.
    /// The centre follows the strip's tilt and is blended through the same soft, worn gate.
    /// Dust and crossing scratches are then laid over the centre with the polarity of the chosen
    /// route; rebate-only scratches stay in the material render. Leaks and fog are exposure, so
    /// they enter the centre before its look (`exposeCenter`).
    static func replacingCenter(_ edge: CGImage, with center: CGImage, geometry: FilmEdgeGeometry,
                                paperPrint: Bool = true) throws -> CGImage {
        let rect = geometry.gate
        let gate = CGRect(x: rect.minX, y: Double(geometry.height) - rect.maxY, width: rect.width, height: rect.height)
        let angle = geometry.distress.tilt * .pi / 180
        let mid = CGPoint(x: Double(geometry.width) / 2, y: Double(geometry.height) / 2)
        // Clamp first: the soft, worn or bulged gate may open past the nominal rectangle, and a
        // transparent photo border would blend in as a dark seam.
        let photograph = PixelStore.ciImage(center).clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: gate.width / Double(center.width), y: gate.height / Double(center.height)))
            .transformed(by: CGAffineTransform(translationX: gate.minX, y: gate.minY))
            .transformed(by: CGAffineTransform(translationX: -mid.x, y: -mid.y)
                .concatenating(CGAffineTransform(rotationAngle: -angle))  // y-up: film turns clockwise for +tilt
                .concatenating(CGAffineTransform(translationX: mid.x, y: mid.y)))
        let canvas = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        let mask = try gateCoverageMap(geometry)
        let result = photograph.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: PixelStore.ciImage(edge), kCIInputMaskImageKey: try gateMask(mask, geometry)])
            .cropped(to: canvas)
        let needsPass = needsCenterPass(geometry)
        if PixelStore.isLarge(width: geometry.width, height: geometry.height) {
            // Composite into file-backed storage and lay the damage over it in place.
            let store = try PixelStore.render(
                result, width: geometry.width, height: geometry.height, context: context,
                colorSpace: linear)
            if needsPass {
                var view = UnsafeMutableBufferPointer(
                    start: store.base.assumingMemoryBound(to: SIMD4<Float>.self),
                    count: geometry.width * geometry.height)
                try applyCenterDamage(&view, mask: mask, geometry: geometry, paperPrint: paperPrint)
            }
            return try store.image(colorSpace: linear)
        }
        guard needsPass else {
            guard let image = context.createCGImage(result, from: canvas, format: .RGBAf, colorSpace: linear, deferred: false)
            else { throw PhotoExporter.Failure.render }
            return image
        }
        let w = geometry.width, h = geometry.height
        var pixels = [SIMD4<Float>](repeating: .zero, count: w * h)
        pixels.withUnsafeMutableBytes {
            context.render(result, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: canvas, format: .RGBAf, colorSpace: linear)
        }
        try pixels.withUnsafeMutableBufferPointer {
            try applyCenterDamage(&$0, mask: mask, geometry: geometry, paperPrint: paperPrint)
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let damaged = CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: linear)
        guard let image = context.createCGImage(damaged, from: canvas, format: .RGBAf, colorSpace: linear, deferred: false)
        else { throw PhotoExporter.Failure.render }
        return image
    }

    static func needsCenterPass(_ geometry: FilmEdgeGeometry) -> Bool {
        let d = geometry.distress
        return d.dust > 0 || (d.scratches > 0 && d.scratchesInImage)
    }

    /// Unwanted light is exposure, so a creative centre receives it before its LUT or tone: the
    /// same front/back leak and fog fields the film graph uses, in its mid-grey units, added to
    /// the framed source (one pixel per gate position, film millimetres from the frame centre).
    /// The source is display-developed: linear (mid grey 0.184 per unit) up to a knee, then an
    /// exponential shoulder, so added light lifts shadows and mid-tones in proportion to exposure
    /// and highlights saturate instead of clipping.
    static func exposeCenter(_ input: SourceImageRenderer.Input, geometry: FilmEdgeGeometry) throws
        -> SourceImageRenderer.Input
    {
        let d = geometry.distress
        guard d.leak > 0 || d.edgeFog > 0 else { return input }
        let w = input.width, h = input.height
        let one = SIMD3<Double>(repeating: 1)
        let lt = geometry.leakLight(neutral: one), ft = geometry.fogLight(neutral: one)
        let leakTint = SIMD3<Float>(Float(lt.x), Float(lt.y), Float(lt.z))
        let fogTint = SIMD3<Float>(Float(ft.x), Float(ft.y), Float(ft.z))
        let knee: Float = 0.5, room = 1 - knee
        func linearized(_ v: Float) -> Float { v < knee ? v : knee - room * log((1 - v) / room) }
        func shouldered(_ y: Float) -> Float { y < knee ? y : 1 - room * exp(-(y - knee) / room) }
        let mm = geometry.millimetersPerPixel, gate = geometry.gate
        let cx = Double(geometry.width) / 2, cy = Double(geometry.height) / 2
        func expose(_ out: UnsafeMutablePointer<SIMD4<Float>>) throws {
            let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 4))
            nonisolated(unsafe) let out = out
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                for y in (band * h / bands)..<((band + 1) * h / bands) {
                    let py = gate.minY + (Double(y) + 0.5) / Double(h) * gate.height
                    for x in 0..<w {
                        let px = gate.minX + (Double(x) + 0.5) / Double(w) * gate.width
                        let e = geometry.exposureFields(filmX: (px - cx) * mm, filmY: (py - cy) * mm)
                        let light = leakTint * Float(e.front + e.back) + fogTint * Float(e.fog)
                        if light == .zero { continue }
                        let p = out[y * w + x], v = SIMD3(p.x, p.y, p.z)
                        let c = simd_clamp(v, .zero, SIMD3(repeating: 0.999))
                        let lifted = SIMD3(linearized(c.x), linearized(c.y), linearized(c.z)) + 0.184 * light
                        let lit = v + SIMD3(shouldered(lifted.x), shouldered(lifted.y), shouldered(lifted.z)) - c
                        out[y * w + x] = SIMD4(lit.x, lit.y, lit.z, p.w)
                    }
                }
            }
            try Task.checkCancellation()
        }
        if let store = input.store {
            // The framed source is kept between frames; never expose it in place.
            let copy = try PixelStore(width: w, height: h, format: .float)
            copy.base.copyMemory(from: store.base, byteCount: store.length)
            try expose(copy.base.assumingMemoryBound(to: SIMD4<Float>.self))
            return .init(pixels: [], width: w, height: h, store: copy)
        }
        var pixels = input.pixels
        try pixels.withUnsafeMutableBufferPointer { try expose($0.baseAddress!) }
        return .init(pixels: pixels, width: w, height: h)
    }

    /// A creative centre has no developed density to modulate, so apply the visible result of the
    /// same particles. Paper from a negative: opaque dust and scatter print light (scatter bluish),
    /// cut dye prints its complement (a shallow yellow-layer cut prints yellow, deeper red, then
    /// black). Transmission scan: dust and scatter darken; cut dye lets its complementary light
    /// through (shallow blue, deeper cyan, then the scanner's white).
    static func applyCenterDamage(_ pixels: inout UnsafeMutableBufferPointer<SIMD4<Float>>, mask: [Float],
                                  geometry: FilmEdgeGeometry, paperPrint: Bool) throws {
        let w = geometry.width, h = geometry.height
        let paperWhite = SIMD3<Float>(repeating: 0.8), scanLight = SIMD3<Float>(repeating: 0.77)
        let sw = FilmEdgeGeometry.scatterWeights, weights = SIMD3<Float>(Float(sw.x), Float(sw.y), Float(sw.z))
        let crossing = geometry.distress.scratchesInImage && geometry.distress.scratches > 0
        let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 4))
        do {
            nonisolated(unsafe) let out = pixels.baseAddress!
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                for y in (band * h / bands)..<((band + 1) * h / bands) {
                    for x in 0..<w {
                        let g = mask[y * w + x]
                        if g <= 0 { continue }
                        let p = out[y * w + x]
                        var v = SIMD3(p.x, p.y, p.z)
                        let scratch = crossing ? geometry.scratchFields(x: x, y: y) : FilmEdgeGeometry.ScratchFields()
                        let dust = Float(geometry.dustOcclusion(x: x, y: y)) * g
                        let scatter = Float(scratch.scatter) * g * weights
                        let cut = SIMD3<Float>(Float(scratch.removal.x), Float(scratch.removal.y), Float(scratch.removal.z)) * g
                        if paperPrint {
                            v = v * (1 - dust) + paperWhite * dust
                            v = v + (paperWhite - v) * scatter
                            v = v * (1 - cut)
                        } else {
                            v = v * (1 - dust) * (1 - scatter)
                            v = v + (scanLight - v) * cut
                        }
                        if v == SIMD3(p.x, p.y, p.z) { continue }
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
        let bands = max(1, min(h / 16, ProcessInfo.processInfo.activeProcessorCount * 4))
        values.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                for y in (band * h / bands)..<((band + 1) * h / bands) {
                    for x in 0..<w {
                        let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                        out[y * w + x] = inner.contains(p) ? 1 : outer.contains(p) ? Float(geometry.gateCoverage(x: x, y: y)) : 0
                    }
                }
            }
        }
        try Task.checkCancellation()
        return values
    }
    static func gateMask(_ values: [Float], _ geometry: FilmEdgeGeometry) throws -> CIImage {
        let bytes = values.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        // Like CIImage(cgImage:), the first bitmap row is the top of the canvas.
        return CIImage(bitmapData: Data(bytes), bytesPerRow: geometry.width,
                       size: CGSize(width: geometry.width, height: geometry.height), format: .L8, colorSpace: nil)
    }
}
