import CoreGraphics
import CoreImage
import CryptoKit
import Foundation

@main struct RenderCacheChecks {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static func pixels(_ image: CGImage) -> [SIMD4<Float>] {
        var result = [SIMD4<Float>](repeating: .zero, count: image.width * image.height)
        result.withUnsafeMutableBytes {
            context.render(
                CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: image.width * 16,
                bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return result
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let resources = FilmRenderResources(directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"))
        for file in CommandLine.arguments.dropFirst(2) {
            let url = URL(fileURLWithPath: file)
            let data = try Data(contentsOf: url)
            let originalHash = SHA256.hash(data: data)
            let photo = ImportedPhoto.decode(data, maximum: 192, typeHint: PhotoSource.typeHint(for: url))!
            let sharedPreview = ImportedPhoto.decode(
                data, maximum: 96, typeHint: photo.sourceType, neutralPreview: photo.preview)!
            precondition(max(sharedPreview.preview.width, sharedPreview.preview.height) <= 96)
            precondition(sharedPreview.width == photo.width && sharedPreview.sourceDescription?.isRAW == photo.sourceDescription?.isRAW)
            for intent in [SourceImageRenderer.Intent.sceneLinear, .developedPhoto] {
                let decoder = SourceImageRenderer.Decoder()
                for (exposure, tint, temperature) in [(0.0, 0.0, photo.rawTemperature), (0.7, 15.0, 4500.0), (-0.7, -20.0, 7200.0), (0.0, 0.0, photo.rawTemperature)] {
                    var recipe = EditRecipe()
                    recipe.temperature = temperature
                    recipe.source.exposureEV = exposure
                    recipe.source.tint = tint
                    let cached = try SourceImageRenderer.prepare(
                        data: data, fallback: photo.preview, recipe: recipe, maximum: 96,
                        sourceType: photo.sourceType, intent: intent,
                        description: photo.sourceDescription, decoder: decoder)
                    let fresh = try SourceImageRenderer.prepare(
                        data: data, fallback: photo.preview, recipe: recipe, maximum: 96,
                        sourceType: photo.sourceType, intent: intent)
                    precondition(cached.width == fresh.width && cached.height == fresh.height)
                    let error = zip(cached.pixels, fresh.pixels).reduce(Float(0)) {
                        max($0, abs($1.0.x - $1.1.x), abs($1.0.y - $1.1.y), abs($1.0.z - $1.1.z))
                    }
                    let displayError = zip(
                        pixels(try SourceImageRenderer.workingImage(cached)),
                        pixels(try SourceImageRenderer.workingImage(fresh))
                    ).reduce(Float(0)) {
                        max($0, abs($1.0.x - $1.1.x), abs($1.0.y - $1.1.y), abs($1.0.z - $1.1.z))
                    }
                    print("RAW cache control", intent, exposure, tint, "linear error", error, "sRGB error255", displayError * 255)
                    precondition(displayError <= 1.1 / 255, "Cached RAW decode changed color: \(displayError)")
                }
            }
            func renderer() -> PhotoRenderer {
                PhotoRenderer(
                    source: photo.preview, directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"),
                    data: data, temperature: photo.rawTemperature, previewMaximum: 192,
                    resources: resources, sourceType: photo.sourceType, description: photo.sourceDescription)
            }
            let cached = renderer()
            var recipe = EditRecipe(); recipe.temperature = photo.rawTemperature
            recipe.flags["film_render.grain.active"] = false
            recipe.flags["film_render.halation.active"] = false
            for index in 0..<8 {
                recipe.look.mode = index == 3 || index == 4 ? .lut : .spektrafilm
                recipe.source.exposureEV = index == 2 || index == 4 ? 0.5 : 0
                recipe.mix = index % 2 == 0 ? 0.5 : 1
                let maximum = index % 2 == 0 ? 96 : 192
                let actual = try await cached.render(recipe, maximum: maximum)
                let expected = try await renderer().render(recipe, maximum: maximum)
                precondition(actual.width == expected.width && actual.height == expected.height)
                let error = zip(pixels(actual), pixels(expected)).reduce(Float(0)) {
                    max($0, abs($1.0.x - $1.1.x), abs($1.0.y - $1.1.y), abs($1.0.z - $1.1.z))
                }
                precondition(error <= 1.1 / 255, "Preview cache retained stale pixels: \(error)")
            }
            await cached.releasePreviewCaches()
            _ = try await cached.render(recipe)
            let concurrentRecipe = recipe
            async let left = renderer().render(concurrentRecipe)
            async let right = renderer().render(concurrentRecipe)
            let (first, second) = try await (left, right)
            let simultaneousError = zip(pixels(first), pixels(second)).reduce(Float(0)) {
                max($0, abs($1.0.x - $1.1.x), abs($1.0.y - $1.1.y), abs($1.0.z - $1.1.z))
            }
            precondition(simultaneousError <= 1.1 / 255, "Shared GPU requests corrupted each other")
            let after = try Data(contentsOf: url)
            precondition(SHA256.hash(data: after) == originalHash)
            print("PASS:", url.lastPathComponent, "cached/fresh RAW exposure, tint and WB; two preview sizes, mode changes, eviction and original hash")
        }
    }
}
