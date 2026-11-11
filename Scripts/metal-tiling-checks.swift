import Foundation

/// The tiled export graph must reproduce the whole-frame graph: narrow kernels exactly inside
/// each tile's halo, wide kernels through the low-resolution proxy.
@main struct Checks {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = root.appendingPathComponent("SpektraCam/Resources/ModelData")
        let names = ["ColorPipeline", "Spatial", "Grain", "Diffusion", "FilmPipeline"]
        let sources = try names.map {
            try String(contentsOf: data.appendingPathComponent($0 + ".metalSource"), encoding: .utf8)
        }
        let gpu = try MetalFilmPipeline(sources: sources)
        let library = try ModelLibrary(directory: data)
        // A scene with smooth gradients, hard edges, texture and small speculars far above white.
        let width = 1400, height = 1000
        var input = [SIMD4<Float>](repeating: .zero, count: width * height)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
        for y in 0..<height {
            for x in 0..<width {
                let u = Float(x) / Float(width), v = Float(y) / Float(height)
                var value = SIMD3<Float>(0.02 + 0.5 * u, 0.05 + 0.4 * v, 0.3 * (1 - u) + 0.05)
                if (x / 97 + y / 61) % 2 == 0 { value *= 0.35 }
                value *= 0.9 + 0.2 * random()
                input[y * width + x] = SIMD4(value.x, value.y, value.z, 1)
            }
        }
        for _ in 0..<40 {
            let cx = Int(random() * Float(width - 8)) + 4, cy = Int(random() * Float(height - 8)) + 4
            let level = 4 + 60 * random()
            for dy in -2...2 {
                for dx in -2...2 { input[(cy + dy) * width + cx + dx] = SIMD4(level, level * 0.9, level * 0.7, 1) }
            }
        }
        var tiling = MetalFilmPipeline.Tiling()
        tiling.tileEdge = 512
        tiling.transform = 512
        tiling.factor = 4
        let environment = ProcessInfo.processInfo.environment
        if let v = environment["TILE_HALO"].flatMap(Double.init) { tiling.haloSigmas = v }
        func recipe(_ change: (inout EditRecipe) -> Void) -> EditRecipe {
            var recipe = EditRecipe()
            recipe.flags["camera.auto_exposure"] = false
            change(&recipe)
            return recipe
        }
        // The proxy carries kernels wider than about 140 um on film, as a full-size export does:
        // factor 8 at the 4.3 um pitch of a 48 MP frame, factor 4 at the 8.6 um pitch of 12 MP.
        func tiles(_ factor: Int, _ edge: Int = 512, proxy: Double = 4) -> MetalFilmPipeline.Tiling {
            var value = tiling
            value.factor = environment["TILE_FACTOR"].flatMap(Int.init) ?? factor
            value.tileEdge = environment["TILE_EDGE"].flatMap(Int.init) ?? edge
            value.transform = value.tileEdge
            value.proxySigmas = environment["TILE_PROXY"].flatMap(Double.init) ?? proxy
            if let v = environment["TILE_GLOW"].flatMap(Double.init) { value.glowSigmas = v }
            if let v = environment["TILE_HALO"].flatMap(Double.init) { value.haloSigmas = v }
            return value
        }
        let cases: [(String, EditRecipe, Bool, Double, MetalFilmPipeline.Tiling)] = [
            ("default", recipe { _ in }, false, 2e-3, tiles(2, proxy: 3)),
            ("default + grain", recipe { _ in }, true, 2e-3, tiles(2, proxy: 3)),
            ("fine pitch", recipe { $0.numbers["camera.film_format_mm"] = 6 }, false, 2e-3, tiles(8, 1024)),
            ("fine pitch + grain", recipe { $0.numbers["camera.film_format_mm"] = 6 }, true, 2e-3, tiles(8, 1024)),
            ("medium pitch", recipe { $0.numbers["camera.film_format_mm"] = 12 }, false, 2e-3, tiles(4)),
            (
                "boost + wide halation",
                recipe {
                    $0.numbers["camera.film_format_mm"] = 6
                    $0.numbers["film_render.halation.boost_ev"] = 1
                    $0.numbers["film_render.halation.halation_spatial_scale"] = 3
                    $0.numbers["film_render.halation.scatter_spatial_scale"] = 3
                }, false, 3e-3, tiles(8, 1024)
            ),
            (
                "camera diffusion",
                recipe {
                    $0.numbers["camera.film_format_mm"] = 6
                    $0.flags["camera.diffusion_filter.active"] = true
                }, false, 8e-3, tiles(8, 1024)
            ),
            (
                "both diffusions",
                recipe {
                    $0.numbers["camera.film_format_mm"] = 12
                    $0.flags["camera.diffusion_filter.active"] = true
                    $0.flags["enlarger.diffusion_filter.active"] = true
                    $0.choices["enlarger.diffusion_filter.filter_family"] = "glimmerglass"
                }, false, 8e-3, tiles(4, 1024)
            ),
            (
                "cinebloom, wide",
                recipe {
                    $0.numbers["camera.film_format_mm"] = 12
                    $0.flags["camera.diffusion_filter.active"] = true
                    $0.choices["camera.diffusion_filter.filter_family"] = "cinebloom"
                    $0.numbers["camera.diffusion_filter.spatial_scale"] = 2
                    $0.numbers["camera.diffusion_filter.strength"] = 1
                }, false, 8e-3, tiles(4, 1024)
            ),
            (
                "slide scan",
                recipe {
                    $0.filmID = "fujifilm_provia_100f"
                    $0.scanFilm = true
                    $0.numbers["camera.film_format_mm"] = 6
                }, true, 2e-3, tiles(8, 1024)
            ),
            ("monochrome grain", recipe { $0.monochromeGrain = true }, true, 2e-3, tiles(2, proxy: 3)),
        ]
        var failed = false
        for (name, recipe, stochastic, tolerance, tiling) in cases {
            if let only = CommandLine.arguments.dropFirst(2).first(where: { !$0.hasPrefix("--") }), !name.contains(only) { continue }
            let model = try FilmPipeline(library: library, recipe: recipe)
            let started = Date()
            let whole = try await gpu.process(
                input, width: width, height: height, pipeline: model, stochastic: stochastic,
                seed: 7, autoExposureEV: 0)
            let middle = Date()
            let tiled = try await gpu.processTiled(
                input, width: width, height: height, pipeline: model, stochastic: stochastic,
                seed: 7, autoExposureEV: 0, tiling: tiling)
            var maximum = 0.0, total = 0.0
            var worst = 0, outliers = 0
            for i in whole.pixels.indices {
                for c in 0..<3 {
                    let error = abs(Double(whole.pixels[i][c]) - Double(tiled[i][c]))
                    precondition(error.isFinite, "\(name): non-finite value at \(i)")
                    total += error
                    if error > 1.0 / 255 { outliers += 1 }
                    if error > maximum {
                        maximum = error
                        worst = i
                    }
                }
            }
            let mean = total / Double(3 * whole.pixels.count)
            print(
                String(
                    format: "%@: max %.5f (%.2f/255) at (%d,%d), mean %.6f, over 1/255: %.4f%%; whole %.2fs tiled %.2fs",
                    name, maximum, maximum * 255, worst % width, worst / width, mean,
                    100 * Double(outliers) / Double(3 * whole.pixels.count),
                    middle.timeIntervalSince(started), Date().timeIntervalSince(middle)))
            if CommandLine.arguments.contains("--map") {
                for y in stride(from: max(0, worst / width - 24), to: min(height, worst / width + 24), by: 4) {
                    var line = String(format: "y%4d ", y)
                    for x in stride(from: max(0, worst % width - 6), to: min(width, worst % width + 30), by: 3) {
                        let i = y * width + x
                        line += String(format: " %.3f/%.3f(%.2f)", whole.pixels[i].x, tiled[i].x, input[i].x)
                    }
                    print(line)
                }
                for by in stride(from: 0, to: height, by: 50) {
                    var line = ""
                    for bx in stride(from: 0, to: width, by: 50) {
                        var m = 0.0
                        for y in by..<min(by + 50, height) { for x in bx..<min(bx + 50, width) {
                            let i = y * width + x
                            for c in 0..<3 { m = max(m, abs(Double(whole.pixels[i][c]) - Double(tiled[i][c]))) }
                        } }
                        line += String(format: "%3d", min(999, Int(m * 255 * 100)))
                    }
                    print(line)
                }
            }
            // A Poisson count can change by one grain when its mean moves by rounding error,
            // so stochastic cases are compared statistically rather than pixel by pixel.
            if stochastic {
                precondition(mean < 4e-4, "\(name): tiled grain differs on average by \(mean)")
            } else {
                if maximum >= tolerance { print("FAIL \(name): tiled render differs by \(maximum)"); failed = true }
            }
        }
        // Zoomed preview: a region rendered from a low-resolution capture of the whole frame
        // must match the same area of the whole-frame render.
        for (name, recipe, _, _, tiling) in cases where !name.contains("grain") && name != "slide scan" {
            if let only = CommandLine.arguments.dropFirst(2).first(where: { !$0.hasPrefix("--") }), !name.contains(only) { continue }
            let model = try FilmPipeline(library: library, recipe: recipe)
            let factor = tiling.resolvedFactor(width: width, height: height)
            let pw = (width + factor - 1) / factor, ph = (height + factor - 1) / factor
            var proxy = [SIMD4<Float>](repeating: .zero, count: pw * ph)
            for y in 0..<ph { for x in 0..<pw {
                var sum = SIMD4<Float>.zero; var n: Float = 0
                for yy in (y * factor)..<min((y + 1) * factor, height) { for xx in (x * factor)..<min((x + 1) * factor, width) {
                    sum += input[yy * width + xx]; n += 1
                } }
                proxy[y * pw + x] = sum / n
            } }
            let whole = try await gpu.process(
                input, width: width, height: height, pipeline: model, stochastic: false, seed: 7, autoExposureEV: 0)
            var still = recipe
            still.flags["film_render.grain.active"] = false
            still.flags["print_render.glare.active"] = false
            let quiet = try FilmPipeline(library: library, recipe: still)
            let started = Date()
            guard let halo = try await gpu.prepareRegion(
                width: width, height: height, factor: factor, pipeline: quiet, seed: 7,
                autoExposureEV: 0, tiling: tiling, proxy: proxy) else { preconditionFailure("no halo") }
            let prepared = Date()
            let region = (x: 520, y: 300, w: 400, h: 360)
            let x0 = max(0, region.x - halo), y0 = max(0, region.y - halo)
            let x1 = min(width, region.x + region.w + halo), y1 = min(height, region.y + region.h + halo)
            let source = try PixelStore(width: x1 - x0, height: y1 - y0, format: .float)
            input.withUnsafeBytes { bytes in
                for row in 0..<(y1 - y0) {
                    memcpy(source.base.advanced(by: row * source.rowBytes), bytes.baseAddress!.advanced(by: ((y0 + row) * width + x0) * 16), source.rowBytes)
                }
            }
            let key = MetalFilmPipeline.RegionKey(recipe: quiet.recipe, width: width, height: height, factor: factor, autoExposureEV: 0, seed: 7)
            let result = try await gpu.processRegion(source, origin: (x0, y0), region: region, key: key, pipeline: quiet)
            let values = result.base.assumingMemoryBound(to: SIMD4<Float>.self)
            var maximum = 0.0, total = 0.0
            for y in 0..<region.h { for x in 0..<region.w {
                let a = whole.pixels[(region.y + y) * width + region.x + x], b = values[y * region.w + x]
                for c in 0..<3 { let e = abs(Double(a[c]) - Double(b[c])); precondition(e.isFinite); maximum = max(maximum, e); total += e }
            } }
            print(String(format: "region %@: halo %d, max %.5f (%.2f/255), mean %.6f; prepare %.2fs render %.2fs",
                         name, halo, maximum, maximum * 255, total / Double(3 * region.w * region.h),
                         prepared.timeIntervalSince(started), Date().timeIntervalSince(prepared)))
            // Highlight boost is anchored to the proxy's brightest value, as a preview of that size is.
            if maximum >= 0.02 && !name.contains("boost") { print("FAIL region \(name)"); failed = true }
        }
        precondition(!failed, "tiled film graph differs from the whole-frame graph")
        print("PASS: tiled film graph matches the whole-frame graph")
    }
}
