import CoreGraphics
import CoreImage
import Foundation

@main struct Checks {
    static func main() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let values: [UInt8] = (0..<256).flatMap { [UInt8($0), UInt8($0), UInt8($0), UInt8(255)] }
        let image = CGImage(
            width: 256, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 1024, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(values) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
        var tone = EditRecipe.Tone()
        tone.algorithm = 4
        let neutral = try ToneRenderer.render(image, tone: tone)
        precondition(neutral === image, "Neutral tone changed the frame")
        for pivot in [0.0, 0.1, 0.35, 0.435, 0.9, 1.0] {
            tone.pivot = pivot
            for contrast in [0.25, 0.5, 1.0, 1.5, 2.0] {
                tone.contrast = contrast
                let ramp = (0...1000).map { ToneRenderer.curve(Double($0) / 1000, tone: tone) }
                precondition(ramp.allSatisfy { $0.isFinite && (0...1).contains($0) })
                precondition(
                    zip(ramp, ramp.dropFirst()).allSatisfy { $0 <= $1 },
                    "Curve reversed tonal order")
                precondition(ramp.first == 0 && ramp.last == 1, "Curve clipped its endpoints")
                if (0.001...0.999).contains(pivot) {
                    precondition(abs(ToneRenderer.curve(pivot, tone: tone) - pivot) < 1e-10)
                }
            }
        }
        for shadow in [-1.0, 0, 1] {
            for highlight in [-1.0, 0, 1] {
                tone = EditRecipe.Tone()
                tone.algorithm = 4
                tone.algorithm = 1
                tone.shadows = shadow
                tone.highlights = highlight
                tone.contrast = 1.4
                let ramp = (0...1000).map { ToneRenderer.curve(Double($0) / 1000, tone: tone) }
                precondition(zip(ramp, ramp.dropFirst()).allSatisfy { $0 <= $1 })
                let p = tone.pivot
                let h = 0.000001
                let left =
                    (ToneRenderer.curve(p, tone: tone) - ToneRenderer.curve(p - h, tone: tone)) / h
                let right =
                    (ToneRenderer.curve(p + h, tone: tone) - ToneRenderer.curve(p, tone: tone)) / h
                precondition(
                    abs(left - right) < 0.0001, "Tonal controls create a kink at the pivot")
            }
        }
        tone = EditRecipe.Tone()
        tone.algorithm = 4
        tone.contrast = 1.5
        let rendered = try ToneRenderer.render(image, tone: tone)
        let pixels = try PhotoColorBridge.decode(rendered)
        var error = 0.0
        for i in 0..<256 {
            let expected = ToneRenderer.curve(Double(i) / 255, tone: tone)
            let y = expected <= 0.04045 ? expected / 12.92 : pow((expected + 0.055) / 1.055, 2.4)
            error = max(error, abs(Double(pixels[i].x) - y))
        }
        precondition(error < 0.01, "Native curve uses the wrong working space: \(error)")
        tone = EditRecipe.Tone()
        tone.algorithm = 4
        tone.shadows = 1
        precondition(ToneRenderer.curve(0.15, tone: tone) > 0.15)
        tone = EditRecipe.Tone()
        tone.algorithm = 4
        tone.algorithm = 1
        tone.highlights = -1
        precondition(ToneRenderer.curve(0.75, tone: tone) < 0.75)
        let color = try PhotoColorBridge.encode(
            [SIMD4<Float>(0.7, 0.35, 0.2, 1)], width: 1, height: 1)
        tone = EditRecipe.Tone()
        tone.algorithm = 4
        tone.monochrome = true
        let gray = try PhotoColorBridge.decode(ToneRenderer.render(color, tone: tone))[0]
        precondition(abs(gray.x - gray.y) < 0.0001 && abs(gray.y - gray.z) < 0.0001)
        // The overexposed display may be white, while the working image must keep distinct values.
        let hdrSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let hdrPixels: [SIMD4<Float>] = [.init(0.2, 0.2, 0.2, 1), .init(0.4, 0.4, 0.4, 1)]
        let hdrData = hdrPixels.withUnsafeBytes { Data($0) }
        let hdrInput = CIImage(
            bitmapData: hdrData, bytesPerRow: 32, size: CGSize(width: 2, height: 1), format: .RGBAf,
            colorSpace: hdrSpace)
        let hdrContext = CIContext(options: [
            .workingColorSpace: hdrSpace, .workingFormat: CIFormat.RGBAf,
        ])
        let hdrImage = hdrContext.createCGImage(
            hdrInput, from: hdrInput.extent, format: .RGBAf, colorSpace: hdrSpace)!
        tone = EditRecipe.Tone()
        tone.algorithm = 4
        tone.exposureEV = 4
        let over = try PhotoColorBridge.decode(ToneRenderer.working(hdrImage, tone: tone))
        precondition(
            over[0].x > 3 && over[1].x > 6 && over[1].x > over[0].x,
            "Exposure clipped the working image")
        tone.highlights = -2
        let recovered = try PhotoColorBridge.decode(ToneRenderer.render(hdrImage, tone: tone))
        precondition(
            recovered[1].x < 1 && recovered[1].x - recovered[0].x > 0.05,
            "Highlights cannot recover distinct bright values")
        tone = EditRecipe.Tone()
        tone.algorithm = 4
        tone.exposureEV = -3
        tone.shadows = 1
        let low = try PhotoColorBridge.decode(ToneRenderer.working(hdrImage, tone: tone))
        precondition(low[0].x > 0 && low[1].x > low[0].x)
        print(
            "PASS: float exposure headroom, highlight recovery, shadow detail and final SDR conversion"
        )
        for shadow in [-2.0, -1, 0, 1, 2] {
            tone = EditRecipe.Tone()
            tone.algorithm = 4
            tone.algorithm = 3
            tone.shadows = shadow
            let result = try PhotoColorBridge.decode(ToneRenderer.working(image, tone: tone))
            precondition(
                result.allSatisfy { $0.x.isFinite && $0.x >= 0 },
                "Wide shadow range produced invalid light")
            precondition(
                zip(result, result.dropFirst()).allSatisfy { $0.x <= $1.x },
                "Wide shadows reversed tonal order")
        }
        let legacy = try JSONDecoder().decode(EditRecipe.self, from: Data("{\"version\":1}".utf8))
        precondition(legacy.version == 4 && legacy.tone.isIdentity && !legacy.monochromeGrain)
        for version in 1...5 {
            var savedTone = EditRecipe.Tone()
            savedTone.algorithm = version
            savedTone.contrast = 1.3
            let restoredTone = try JSONDecoder().decode(
                EditRecipe.Tone.self, from: JSONEncoder().encode(savedTone))
            precondition(restoredTone == savedTone, "Curve version changed during restart")
        }
        var stronger = EditRecipe.Tone()
        stronger.contrast = 1.5
        precondition(
            ToneRenderer.curve(0.2, tone: stronger) < 0.2
                && ToneRenderer.curve(0.7, tone: stronger) > 0.7)
        var weaker = EditRecipe.Tone()
        weaker.contrast = 0.5
        precondition(
            ToneRenderer.curve(0.2, tone: weaker) > 0.2
                && ToneRenderer.curve(0.7, tone: weaker) < 0.7)
        var neutralPivot = EditRecipe.Tone()
        neutralPivot.pivot = 0.7
        precondition(ToneRenderer.curve(0.2, tone: neutralPivot) == 0.2)
        var recipe = EditRecipe()
        recipe.tone.contrast = 1.3
        recipe.tone.algorithm = 3
        recipe.tone.shadows = -2
        recipe.monochromeGrain = true
        let restored = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        precondition(restored == recipe, "New controls did not survive recipe restart")
        print(
            "PASS: identity, monotonic S-curve, fixed pivot, bounded endpoints, native curve color space (max linear error \(error)), tonal direction, neutral B&W and recipe migration"
        )
    }
}
