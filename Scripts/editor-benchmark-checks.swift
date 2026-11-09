import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Local processing benchmark; no app settings, source files or stored edits are changed.
@main struct EditorBenchmark {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = root.appendingPathComponent("SpektraCam/Resources/ModelData")
        let context = CGContext(data: nil, width: 720, height: 480, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.45, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 720, height: 480))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 100, y: 100, width: 130, height: 180))
        let source = context.makeImage()!
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, source, nil)
        precondition(CGImageDestinationFinalize(destination))
        let data = encoded as Data
        let resources = FilmRenderResources(directory: directory)
        let (library, gpu) = try await resources.load()
        var recipe = EditRecipe()
        recipe.flags["film_render.grain.active"] = false
        recipe.flags["camera.auto_exposure"] = false
        let values = [0.15, 0.3, 0.45, 0.6, 0.75, 0.9]
        var setupTimes = [Double](), frameTimes = [Double]()
        func now() -> Double { ProcessInfo.processInfo.systemUptime }
        _ = try await resources.pipeline(recipe)
        for value in values {
            recipe.tone.exposureEV = value
            let started = now()
            _ = try await resources.pipeline(recipe)
            setupTimes.append((now() - started) * 1000)
        }
        let renderer = PhotoRenderer(source: source, directory: directory, data: data,
            previewMaximum: 720, resources: resources)
        _ = try await renderer.render(recipe, maximum: 720)
        for value in values {
            recipe.tone.exposureEV = value
            let started = now()
            _ = try await renderer.render(recipe, maximum: 720)
            frameTimes.append((now() - started) * 1000)
        }
        let input = try SourceImageRenderer.prepare(data: data, fallback: source, recipe: recipe, maximum: 720)
        var maximumError: Float = 0
        for value in [-0.7, 0.0, 0.7] {
            recipe.tone.exposureEV = value
            recipe.tone.contrast = 1.1
            recipe.tone.shadows = 0.2
            let reused = try await resources.pipeline(recipe)
            let fresh = try FilmPipeline(library: library, recipe: recipe)
            let a = try PhotoColorBridge.decode(await gpu.processImage(input.pixels, width: input.width,
                height: input.height, pipeline: reused, autoExposureEV: 0))
            let b = try PhotoColorBridge.decode(await gpu.processImage(input.pixels, width: input.width,
                height: input.height, pipeline: fresh, autoExposureEV: 0))
            for (x,y) in zip(a,b) { maximumError = max(maximumError, abs(x.x-y.x), abs(x.y-y.y), abs(x.z-y.z)) }
        }
        precondition(maximumError < 1e-5, "Cached material setup changed tone output: \(maximumError)")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EditRecipe())) as! [String: Any]
        var look = json["look"] as! [String: Any]
        look["enabled"] = false
        json["look"] = look
        let neutral = try JSONDecoder().decode(EditRecipe.self, from: JSONSerialization.data(withJSONObject: json))
        let independent = PhotoRenderer(source: source, directory: root.appendingPathComponent("MissingModelData"),
            data: data, previewMaximum: 720)
        var noFilmResources = false
        var neutralMilliseconds = 0.0
        do {
            let started = now()
            _ = try await independent.render(neutral)
            neutralMilliseconds = (now() - started) * 1000
            let exported = try await independent.export(neutral, size: .full, format: .png, quality: 1)
            precondition(exported.1 == 720 && exported.2 == 480)
            try FileManager.default.removeItem(at: exported.0)
            noFilmResources = true
        } catch {
            if CommandLine.arguments.contains("--require-neutral") { throw error }
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let report: [String: Any] = ["setupMedianMS": median(setupTimes), "setupMS": setupTimes,
            "sliderFrameMedianMS": median(frameTimes), "sliderFrameMS": frameTimes,
            "cachedFreshMaximumError": maximumError, "neutralNeedsNoFilmResources": noFilmResources,
            "neutralPreviewMS": neutralMilliseconds, "dimensions": [720,480]]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys,.prettyPrinted]), as: UTF8.self))
    }
}
