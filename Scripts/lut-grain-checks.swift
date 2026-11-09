import Foundation

/// Diagnostic sweep: verify density expectations and inspect the LUT grain adapter.
@main struct LUTGrainChecks {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            .appendingPathComponent("SpektraCam/Resources/ModelData")
        let sources = try ["ColorPipeline", "Spatial", "Grain", "Diffusion", "FilmPipeline"].map {
            try String(contentsOf: directory.appendingPathComponent($0 + ".metalSource"), encoding: .utf8)
        }
        let gpu = try MetalFilmPipeline(sources: sources)
        let library = try ModelLibrary(directory: directory)
        if CommandLine.arguments.count >= 6 {
            let url = URL(fileURLWithPath: CommandLine.arguments[2])
            let base = URL(fileURLWithPath: CommandLine.arguments[5])
            let data = try Data(contentsOf: url)
            let photo = ImportedPhoto.decode(data, typeHint: PhotoSource.typeHint(for: url))!
            let saved = try JSONDecoder().decode(EditRecipe.self, from: Data(contentsOf:
                URL(fileURLWithPath: CommandLine.arguments[3])))
            let maximum = CommandLine.arguments.firstIndex(of: "--maximum").flatMap {
                $0 + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[$0 + 1]) : nil
            } ?? 1080
            let renderer = PhotoRenderer(source: photo.preview, directory: directory, data: data,
                temperature: photo.rawTemperature, lutDirectory: URL(fileURLWithPath: CommandLine.arguments[4]),
                previewMaximum: maximum,
                sourceType: photo.sourceType)
            for mode in ["off", "color", "mono"] {
                var recipe = saved
                recipe.flags["film_render.grain.active"] = mode != "off"
                recipe.monochromeGrain = mode == "mono"
                let image = try await renderer.render(recipe, maximum: maximum)
                let output = try PhotoExporter.write(image, format: .png, directory: base,
                    sourceFilename: "grain-" + mode + ".png")
                print("SAMPLE", mode, output.path)
            }
            return
        }
        let width = 256, height = 192
        for area in [0.2, 10.0] {
            for level: Float in [0, 0.001, 0.01, 0.18, 1, 4] {
                var recipe = EditRecipe()
                recipe.flags["camera.auto_exposure"] = false
                recipe.numbers["film_render.grain.particle_area_um2"] = area
                recipe.flags["film_render.halation.active"] = false
                let pipeline = try FilmPipeline(library: library, recipe: recipe)
                let input = Array(repeating: SIMD4<Float>(level, level, level, 1), count: width * height)
                let pair = try await gpu.processGrainPair(input, width: width, height: height,
                    pipeline: pipeline, autoExposureEV: 0)
                let noisy = try PhotoColorBridge.decode(pair.0)
                let clean = try PhotoColorBridge.decode(pair.1)
                var bypass = recipe
                bypass.flags["film_render.grain.active"] = false
                let ungrained = try await gpu.processGrainPair(input, width: width, height: height,
                    pipeline: FilmPipeline(library: library, recipe: bypass), autoExposureEV: 0)
                let density = try PhotoColorBridge.decode(ungrained.0)[0]
                let model = try GrainCore.Layers(curves: pipeline.color.filmCurve.values,
                    layers: pipeline.film.densityLayers.map { $0.map(ModelLibrary.vector) },
                    positive: pipeline.film.positive)
                let p = pipeline.grain
                let pitch = recipe.number("camera.film_format_mm") * 1000 / Double(width)
                let particles = try model.particlesPerPixel(pixelSize: pitch, area: p.area,
                    scale: p.scale, layerScale: p.layerScale)
                let total = model.maximum.reduce(SIMD3<Double>.zero, +)
                let split = model.densities(.init(Double(density.x), Double(density.y), Double(density.z)))
                var expected = -p.minimum
                for layer in 0..<3 {
                    let minimum = model.maximum[layer] / total * p.minimum
                    for ch in 0..<3 {
                        expected[ch] += try GrainCore.Particle(density: split[layer][ch] + minimum[ch],
                            maximum: model.maximum[layer][ch] + minimum[ch], particles: particles[layer][ch],
                            uniformity: p.uniformity[ch]).mean
                    }
                }
                for value in clean {
                    for ch in 0..<3 { precondition(abs(Double(value[ch]) - expected[ch]) < 0.0005,
                        "GPU grain expectation differs from the CPU density model") }
                }
                var mean = SIMD3<Double>.zero
                var maximum: Float = 0
                for (a,b) in zip(noisy, clean) {
                    let delta = a - b
                    mean += SIMD3(Double(delta.x), Double(delta.y), Double(delta.z))
                    maximum = max(maximum, abs(delta.x), abs(delta.y), abs(delta.z))
                }
                mean /= Double(noisy.count)
                print("PASS: GPU/CPU grain expectation; area", area, "linear input", level,
                    "mean density residual", mean, "max density residual", maximum)
            }
        }
    }
}
