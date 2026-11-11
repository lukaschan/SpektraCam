import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct FilmEdgeChecks {
    typealias RGB = SIMD3<Double>
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = root.appendingPathComponent("SpektraCam/Resources/ModelData")
        let library = try ModelLibrary(directory: directory)
        let gpu = try MetalFilmPipeline(sources: ["ColorPipeline", "Spatial", "Grain", "Diffusion", "FilmPipeline"].map {
            try String(contentsOf: directory.appendingPathComponent($0 + ".metalSource"), encoding: .utf8)
        })
        var recipe = EditRecipe()
        recipe.filmID = "fujifilm_c200"
        recipe.printID = "fujifilm_crystal_archive_typeii"
        recipe.look.enabled = true
        recipe.flags["camera.auto_exposure"] = false
        recipe.flags["print_render.glare.active"] = false
        recipe.numbers["scanner.lens_blur"] = 0
        recipe.numbers["scanner.unsharp_mask[1]"] = 0
        recipe.filmEdgeLayout = FilmEdgeLayout()
        var selection = FilmEdgeSelection()
        selection.mode = .manual
        let geometry = FilmEdgeGeometry(imageSize: CGSize(width: 600, height: 400), layout: FilmEdgeLayout(), longEdge: 256)!
        precondition(abs(FilmEdgeGeometry.holeCenter - 14.0805) < 1e-9)
        precondition(abs(FilmEdgeGeometry.holeCenter - FilmEdgeGeometry.holeAcross / 2 - 12 - 0.6835) < 1e-9,
            "The nominal stock-edge gap was mistaken for a hole-center inset")
        let pitch = geometry.pixelPitchMicrometers
        precondition(abs(pitch * geometry.gate.width - 36000) < 1e-9)
        precondition(geometry.width == 256 && geometry.height == 180)
        var runs = 0, inHole = false
        for x in 0..<geometry.width {
            let hole = geometry.supportCoverage(x: x, y: 0) < 1
            if hole && !inHole { runs += 1 }
            inHole = hole
        }
        precondition(runs == 8, "135 registration must show eight full-size perforation slivers")
        let input = (0..<geometry.width * geometry.height).map { i in
            SIMD4<Float>(Float(i % geometry.width) / Float(geometry.width) * 0.5 + 0.02, 0.18, 0.1, 1)
        }
        let rgb = input.map { RGB(Double($0.x), Double($0.y), Double($0.z)) }
        var metered = recipe
        metered.flags["camera.auto_exposure"] = true
        let meteredPipeline = try FilmPipeline(library: library, recipe: metered)
        do {
            _ = try meteredPipeline.process(rgb, width: geometry.width, height: geometry.height, stochastic: false, edge: geometry)
            preconditionFailure("CPU metered the padded support instead of requiring scene metering")
        } catch SpectralCore.Failure.invalidShape {}
        do {
            _ = try await gpu.process(input, width: geometry.width, height: geometry.height, pipeline: meteredPipeline,
                stochastic: false, edge: geometry)
            preconditionFailure("Metal metered the padded support instead of requiring scene metering")
        } catch MetalFilmPipeline.Failure.invalidShape {}
        var maxError = 0.0
        for type in FilmEdgeType.allCases {
            selection.manualType = type
            recipe.filmEdgeSelection = selection
            let material = FilmEdgeRenderer.materialRecipe(recipe)
            let pipeline = try FilmPipeline(library: library, recipe: material)
            let cpu = try pipeline.process(rgb, width: geometry.width, height: geometry.height,
                stochastic: false, edge: geometry, autoExposureEV: 0)
            let metal = try await gpu.process(input, width: geometry.width, height: geometry.height,
                pipeline: pipeline, stochastic: false, autoExposureEV: 0, edge: geometry)
            for i in cpu.indices { for ch in 0..<3 {
                let error = abs(cpu[i][ch] - Double(metal.pixels[i][ch]))
                maxError = max(maxError, error)
                precondition(error < 1e-4, "Edge CPU/Metal disagreement: \(type), \(i), \(ch): \(error)")
            }}
            let holes = cpu.indices.filter { geometry.supportCoverage(x: $0 % geometry.width, y: $0 / geometry.width) == 0 }
            precondition(!holes.isEmpty, "The narrow reveal lost every perforation sliver")
            if type == .negativePrint {
                for i in holes { precondition(cpu[i] == .zero && metal.pixels[i].x == 0 && metal.pixels[i].y == 0 && metal.pixels[i].z == 0,
                    "Negative-print clear openings did not define an exact black reference") }
            }
            if type != .negativePrint {
                let noisyA = try await gpu.process(input, width: geometry.width, height: geometry.height,
                    pipeline: pipeline, seed: 9, autoExposureEV: 0, edge: geometry)
                let noisyB = try await gpu.process(input, width: geometry.width, height: geometry.height,
                    pipeline: pipeline, seed: 71, autoExposureEV: 0, edge: geometry)
                for i in holes { precondition(noisyA.pixels[i] == noisyB.pixels[i], "Dye/grain appeared in an open hole") }
            }
            let hole = cpu[holes[holes.count / 2]]
            let rebate = cpu[(geometry.height - 2) * geometry.width + geometry.width / 2]
            print("\(type): hole \(hole), intact rebate \(rebate)")
            if type == .negativePrint { precondition(hole.x + hole.y + hole.z < rebate.x + rebate.y + rebate.z) }
            if type == .reversalScan || type == .cinemaPrint { precondition(hole.x + hole.y + hole.z > rebate.x + rebate.y + rebate.z) }
        }
        var roll = FilmEdgeLayout(); roll.format = .roll120
        for size in [CGSize(width: 600, height: 400), CGSize(width: 400, height: 600), CGSize(width: 600, height: 600), CGSize(width: 1200, height: 200)] {
            for format in [FilmEdgeLayout(), roll] {
                let crop = format.constrainedCrop(CropSelection(), imageSize: size)
                let g = FilmEdgeGeometry(imageSize: crop.pixelRect(in: size).size, layout: format, longEdge: 512)!
                precondition(max(g.width, g.height) == 512)
                let expectedRatio = format.format == .roll120 ? 1 : (size.width >= size.height ? 1.5 : 1 / 1.5)
                precondition(abs(g.gate.width / g.gate.height - expectedRatio) < 1e-9)
                precondition(g.gate.minX > 0 && g.gate.minY > 0)
                if format.format == .roll120 {
                    for y in 0..<g.height { for x in 0..<g.width { precondition(g.supportCoverage(x: x, y: y) == 1) } }
                }
            }
        }
        precondition(FilmEdgeGeometry(imageSize: CGSize(width: 600, height: 600), layout: FilmEdgeLayout(), longEdge: 512) == nil,
            "An arbitrary photo ratio silently changed the physical film gate")
        print("PASS: verified KS placement, eight clipped perforations, fixed gates/portrait/120, CPU/Metal four-family agreement (max \(maxError)), transmission polarity and no dye/grain in holes")
        var optical = recipe
        selection.manualType = .negativeScan; optical.filmEdgeSelection = selection
        optical = FilmEdgeRenderer.materialRecipe(optical)
        optical.flags["film_render.dir_couplers.active"] = false
        optical.flags["camera.diffusion_filter.active"] = false
        optical.numbers["camera.lens_blur_um"] = 0
        optical.numbers["film_render.halation.halation_spatial_scale"] = 12
        optical.numbers["film_render.halation.scatter_spatial_scale"] = 12
        var light = Array(repeating: RGB(repeating: 0.001), count: geometry.width * geometry.height)
        let bx = geometry.width / 2, by = Int(ceil(geometry.gate.minY))
        for y in by..<(by + 3) { for x in (bx - 2)...(bx + 2) { light[y * geometry.width + x] = RGB(repeating: 8) } }
        optical.flags["film_render.halation.active"] = false
        let without = try FilmPipeline(library: library, recipe: optical).process(light, width: geometry.width, height: geometry.height,
            stochastic: false, edge: geometry, autoExposureEV: 0)
        optical.flags["film_render.halation.active"] = true
        let with = try FilmPipeline(library: library, recipe: optical).process(light, width: geometry.width, height: geometry.height,
            stochastic: false, edge: geometry, autoExposureEV: 0)
        let probe = (by - 2) * geometry.width + bx
        precondition(geometry.gateCoverage(x: bx, y: by - 2) == 0)
        precondition(abs(with[probe].x - without[probe].x) > 1e-5, "Halation did not expose intact rebate beyond the camera gate")
        print("PASS: exaggerated bright-edge optical probe exposes rebate only after the gate, without painting a universal halo")
        try await checkDistress(library: library, gpu: gpu, recipe: recipe, input: input)
        try await checkWorkflow(root: root, recipe: recipe)
    }

    static func checkDistress(library: ModelLibrary, gpu: MetalFilmPipeline, recipe base: EditRecipe,
                              input: [SIMD4<Float>]) async throws {
        let size = CGSize(width: 600, height: 400)
        func geometry(_ distress: FilmEdgeDistress, longEdge: Int = 256, format: FilmEdgeLayout.Format = .film35,
                      perforation: FilmEdgeGeometry.Perforation = .ks1870) -> FilmEdgeGeometry {
            var layout = FilmEdgeLayout(); layout.format = format; layout.distress = distress
            let image = format == .film35 ? size : CGSize(width: 600, height: 600)
            return FilmEdgeGeometry(imageSize: image, layout: layout, longEdge: longEdge, perforation: perforation)!
        }
        var all = FilmEdgeDistress.Preset.worn.values
        all.seed = 0xC0FFEE; all.carrierRoughness = 0.3; all.leak = 0.5; all.dust = 0.8; all.scratches = 0.9
        all.perforationWear = 1; all.perforationLeak = 0.8; all.tape = 1; all.carrierReflection = 0.8
        let rgb = input.map { RGB(Double($0.x), Double($0.y), Double($0.z)) }
        var selection = FilmEdgeSelection(); selection.mode = .manual
        var maxError = 0.0
        // CPU/Metal agreement with every node active, for every material route.
        var released = all; released.scratchesInImage = true; released.leakKind = .front; released.leakShape = .streak
        released.warmth = -0.5
        for (type, distress, perforation) in FilmEdgeType.allCases.map({ ($0, all, FilmEdgeGeometry.Perforation.ks1870) })
            + [(.cinemaPrint, released, .bh1866), (.negativeScan, released, .bh1866), (.negativePrint, released, .ks1870),
               (.reversalScan, { var f = released; f.leakShape = .flare; f.leakKind = .back; return f }(), .ks1870)] {
            selection.manualType = type
            var recipe = base; recipe.filmEdgeSelection = selection
            let pipeline = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(recipe))
            let g = geometry(distress, perforation: perforation)
            let cpu = try pipeline.process(rgb, width: g.width, height: g.height, stochastic: false, edge: g, autoExposureEV: 0)
            let metal = try await gpu.process(input, width: g.width, height: g.height, pipeline: pipeline,
                stochastic: false, autoExposureEV: 0, edge: g)
            var bad = 0
            for i in cpu.indices { for ch in 0..<3 {
                let error = abs(cpu[i][ch] - Double(metal.pixels[i][ch]))
                maxError = max(maxError, error)
                if error > 1e-3 { bad += 1 }
            }}
            precondition(bad == 0, "Distress CPU/Metal disagreement on \(type): \(bad) values")
        }
        // Amount 0 is exactly the clean edge; positions do not move with strength.
        var muted = all; muted.amount = 0
        var soft = FilmEdgeDistress(); soft.gateSoftness = all.gateSoftness  // physics, not scaled by Amount
        let clean = geometry(FilmEdgeDistress()), zero = geometry(muted), softClean = geometry(soft)
        for y in 0..<clean.height { for x in 0..<clean.width {
            precondition(softClean.gateCoverage(x: x, y: y) == zero.gateCoverage(x: x, y: y)
                && zero.carrierCoverage(x: x, y: y) == 1 && zero.dustOcclusion(x: x, y: y) == 0
                && zero.exposureFields(x: x, y: y).back == 0 && zero.exposureFields(x: x, y: y).fog == 0
                && zero.tapeTransmission(x: x, y: y) == .one && zero.carrierReflection(x: x, y: y) == 0
                && zero.supportCoverage(x: x, y: y) == softClean.supportCoverage(x: x, y: y), "Amount 0 was not the clean edge")
        }}
        var half = all; half.amount = 0.5
        let a = geometry(all), b = geometry(half)
        precondition(a.leakFrame.point == b.leakFrame.point && a.scratchCandidates.map(\.across) == b.scratchCandidates.map(\.across),
            "Strength reshuffled seeded features")
        var reseeded = all; reseeded.seed = 7
        precondition(geometry(reseeded).scratchCandidates.map(\.across) != a.scratchCandidates.map(\.across), "Seed had no effect")
        // Physical size, not pixels: dust and carrier area agree between 256 and 1024 pixels.
        func area(_ g: FilmEdgeGeometry, _ value: (FilmEdgeGeometry, Int, Int) -> Double) -> Double {
            var sum = 0.0
            for y in 0..<g.height { for x in 0..<g.width { sum += value(g, x, y) } }
            return sum * g.millimetersPerPixel * g.millimetersPerPixel
        }
        let small = geometry(all, longEdge: 256), large = geometry(all, longEdge: 1024)
        let dustSmall = area(small) { $0.dustOcclusion(x: $1, y: $2) }, dustLarge = area(large) { $0.dustOcclusion(x: $1, y: $2) }
        let carrierSmall = area(small) { 1 - $0.carrierCoverage(x: $1, y: $2) }, carrierLarge = area(large) { 1 - $0.carrierCoverage(x: $1, y: $2) }
        precondition(dustLarge > 0 && abs(dustSmall / dustLarge - 1) < 0.25, "Dust area depends on resolution: \(dustSmall) vs \(dustLarge) mm²")
        precondition(abs(carrierSmall / carrierLarge - 1) < 0.08, "Carrier area depends on resolution: \(carrierSmall) vs \(carrierLarge) mm²")
        // Perforations keep full nominal size: without tilt the clean and distressed holes match.
        var straight = all; straight.tilt = 0; straight.perforationWear = 0
        let s = geometry(straight)
        for y in 0..<s.height { for x in 0..<s.width { precondition(s.supportCoverage(x: x, y: y) == clean.supportCoverage(x: x, y: y)) } }
        // 120 has no sprockets, even when distressed.
        let roll = geometry(all, format: .roll120)
        for y in stride(from: 0, to: roll.height, by: 3) { for x in stride(from: 0, to: roll.width, by: 3) { precondition(roll.supportCoverage(x: x, y: y) == 1) } }
        // Opaque dust polarity follows the route: white specks on paper, dark specks in a slide scan.
        var dusty = FilmEdgeDistress(); dusty.dust = 1; dusty.seed = 3
        let d = geometry(dusty)
        var dustIndex: Int?, best = 0.0
        for y in Int(d.gate.minY + 4)..<Int(d.gate.maxY - 4) { for x in Int(d.gate.minX + 4)..<Int(d.gate.maxX - 4) {
            let o = d.dustOcclusion(x: x, y: y); if o > best { best = o; dustIndex = y * d.width + x }
        }}
        precondition(best > 0.3, "No visible dust particle in the test frame")
        let flat = Array(repeating: RGB(repeating: 0.12), count: d.width * d.height)
        for (type, brighter) in [(FilmEdgeType.negativePrint, true), (.reversalScan, false)] {
            selection.manualType = type
            var recipe = base; recipe.filmEdgeSelection = selection
            let pipeline = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(recipe))
            let dirty = try pipeline.process(flat, width: d.width, height: d.height, stochastic: false, edge: d, autoExposureEV: 0)
            let cleanOut = try pipeline.process(flat, width: d.width, height: d.height, stochastic: false, edge: clean, autoExposureEV: 0)
            let i = dustIndex!
            let delta = dirty[i].x + dirty[i].y + dirty[i].z - cleanOut[i].x - cleanOut[i].y - cleanOut[i].z
            precondition(brighter ? delta > 0.01 : delta < -0.01, "Dust polarity wrong for \(type): \(delta)")
        }
        // BH-1866 (cine negative) vs KS-1870: barrel-shaped, shorter along the strip, sharp corners.
        let ks = FilmEdgeGeometry.Perforation.ks1870, bh = FilmEdgeGeometry.Perforation.bh1866
        let c = FilmEdgeGeometry.holeCenter
        func at(_ p: FilmEdgeGeometry.Perforation, _ offset: Double, _ t: Double) -> Bool {
            p.isFilm(along: p.pitch / 2 + offset, across: c + t)
        }
        precondition(!at(ks, 0, 0) && !at(bh, 0, 0), "Perforation centres are not open")
        precondition(!at(ks, 0.95, 0) && at(bh, 0.95, 0), "BH is not 1.854 mm along the strip")
        precondition(!at(bh, 0.9, 1.0) && at(bh, 0.9, 1.25), "BH sides are not the 2.794 mm circle")
        precondition(!at(ks, 0, 1.38) && !at(bh, 0, 1.38) && at(bh, 0, 1.41), "Hole width C changed")
        precondition(abs(bh.pitch - 4.740) < 1e-12 && abs(ks.pitch - 4.750) < 1e-12)
        precondition(FilmEdgeGeometry.Perforation.source(filmID: "kodak_vision3_250d") == .bh1866
            && FilmEdgeGeometry.Perforation.source(filmID: "kodak_portra_400") == .ks1870)
        let bhGeometry = geometry(FilmEdgeDistress(), perforation: .bh1866)
        var bhRuns = 0, open = false
        for x in 0..<bhGeometry.width {
            let hole = bhGeometry.supportCoverage(x: x, y: 0) < 1
            if hole && !open { bhRuns += 1 }; open = hole
        }
        precondition(bhRuns == 8, "BH strip lost its eight perforations per frame")
        // Scratches stay in the rebate unless released; then they may cross the picture.
        var scratched = FilmEdgeDistress(); scratched.scratches = 1; scratched.seed = 11
        func insideScratch(_ g: FilmEdgeGeometry) -> Double {
            var m = 0.0
            for y in Int(g.gate.minY + 3)..<Int(g.gate.maxY - 3) { for x in Int(g.gate.minX + 3)..<Int(g.gate.maxX - 3) {
                let f = g.scratchFields(x: x, y: y); m = max(m, f.scatter, f.removal.z)
            }}
            return m
        }
        precondition(insideScratch(geometry(scratched)) == 0, "Clamped scratches entered the picture")
        var free = scratched; free.scratchesInImage = true
        precondition(insideScratch(geometry(free, longEdge: 1024)) > 0.05, "Released scratches never crossed the picture")
        var rebateHit = 0.0
        let clamped = geometry(scratched, longEdge: 1024)
        for y in 0..<clamped.height { for x in 0..<clamped.width {
            let f = clamped.scratchFields(x: x, y: y); rebateHit = max(rebateHit, f.scatter, f.removal.z)
        }}
        precondition(rebateHit > 0.05, "Clamped scratches vanished from the rebate")
        // Scratch colour follows layer depth and route: a shallow emulsion cut (yellow layer) prints
        // yellow from a negative but shows blue on a slide; scatter prints light and bluish.
        func scratchSeed(_ wanted: (Double) -> Bool) -> UInt32 {
            for seed in UInt32(1)...4000 {
                var d = FilmEdgeDistress(); d.scratches = 0.125; d.scratchesInImage = true; d.seed = seed
                let first = geometry(d).scratchCandidates[0]
                if wanted(first.depth) && abs(first.across) < 8 && first.start < -15 && first.end > 15 { return seed }
            }
            preconditionFailure("No suitable scratch seed")
        }
        for (label, wanted) in [("shallow", { (d: Double) in d > 0.08 && d < 0.3 }), ("scatter", { (d: Double) in d < -0.5 })] {
            var d = FilmEdgeDistress(); d.scratches = 0.125; d.scratchesInImage = true; d.seed = scratchSeed(wanted)
            let g = geometry(d, longEdge: 1024)
            var index = 0, best = 0.0
            for y in Int(g.gate.minY + 8)..<Int(g.gate.maxY - 8) { for x in Int(g.gate.minX + 8)..<Int(g.gate.maxX - 8) {
                let f = g.scratchFields(x: x, y: y); let v = max(f.scatter, f.removal.z)
                if v > best { best = v; index = y * g.width + x }
            }}
            precondition(best > 0.15, "Test scratch not found (\(label))")
            let neutral = Array(repeating: RGB(repeating: 0.12), count: g.width * g.height)
            let plain = geometry(FilmEdgeDistress(), longEdge: 1024)
            for type in [FilmEdgeType.negativePrint, .reversalScan] {
                selection.manualType = type
                var recipe = base; recipe.filmEdgeSelection = selection
                let pipeline = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(recipe))
                let dirty = try pipeline.process(neutral, width: g.width, height: g.height, stochastic: false, edge: g, autoExposureEV: 0)[index]
                let cleanPixel = try pipeline.process(neutral, width: g.width, height: g.height, stochastic: false, edge: plain, autoExposureEV: 0)[index]
                let delta = dirty - cleanPixel
                print("scratch \(label) \(type): Δ \(delta)")
                switch (label, type) {
                case ("shallow", .negativePrint): precondition(delta.z < delta.x - 0.005, "Shallow cut did not print yellow from a negative")
                case ("shallow", _): precondition(delta.z > delta.x + 0.005, "Shallow cut did not look blue on a slide")
                case (_, .negativePrint): precondition(delta.x + delta.y + delta.z > 0.01 && delta.z > delta.x, "Scatter did not print light and bluish")
                default: precondition(delta.x + delta.y + delta.z < -0.01, "Scatter did not darken a slide scan")
                }
            }
        }
        // Worn perforations: edges move by tens of microns, never a resized hole; still eight per frame.
        var wornHoles = FilmEdgeDistress(); wornHoles.perforationWear = 1; wornHoles.seed = 5
        let w = geometry(wornHoles, longEdge: 1024), c0 = geometry(FilmEdgeDistress(), longEdge: 1024)
        var changed = 0, holeArea = 0.0, cleanArea = 0.0, runs = 0, inside = false
        for y in 0..<w.height { for x in 0..<w.width {
            let a = w.supportCoverage(x: x, y: y), b = c0.supportCoverage(x: x, y: y)
            if a != b { changed += 1 }; holeArea += 1 - a; cleanArea += 1 - b
        }}
        for x in 0..<w.width { let hole = w.supportCoverage(x: x, y: 2) < 1; if hole && !inside { runs += 1 }; inside = hole }
        precondition(changed > 50 && abs(holeArea / cleanArea - 1) < 0.08 && runs == 8,
            "Perforation wear: \(changed) px changed, area ratio \(holeArea / cleanArea), \(runs) holes")
        // Perforation fog is hole-shaped exposure next to the holes, 135 only, never in the middle of the picture.
        var perfFog = FilmEdgeDistress(); perfFog.perforationLeak = 1; perfFog.seed = 9
        let pf = geometry(perfFog)
        var nearHoles = 0.0, middle = 0.0
        for y in 0..<pf.height { for x in 0..<pf.width {
            let v = pf.exposureFields(x: x, y: y).fog
            if abs(Double(y) - Double(pf.height) / 2) < Double(pf.height) * 0.2 { middle = max(middle, v) } else { nearHoles = max(nearHoles, v) }
        }}
        precondition(nearHoles > 0.05 && middle == 0, "Perforation fog misplaced: edge \(nearHoles), middle \(middle)")
        precondition(geometry(perfFog, format: .roll120).exposureFields(x: 3, y: 3).fog == 0, "120 grew perforation fog")
        // Front (through-the-lens) light is gated with the scene; a back leak reaches the rebate.
        var frontLeak = FilmEdgeDistress(); frontLeak.leak = 0.8; frontLeak.leakKind = .front; frontLeak.leakPosition = 0.125
        var backLeak = frontLeak; backLeak.leakKind = .back
        selection.manualType = .negativeScan
        var scanRecipe = base; scanRecipe.filmEdgeSelection = selection
        let scanPipeline = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(scanRecipe))
        let gF = geometry(frontLeak), gB = geometry(backLeak)
        let dark = Array(repeating: RGB(repeating: 0.002), count: gF.width * gF.height)
        let none = try scanPipeline.process(dark, width: gF.width, height: gF.height, stochastic: false, edge: clean, autoExposureEV: 0)
        let front = try scanPipeline.process(dark, width: gF.width, height: gF.height, stochastic: false, edge: gF, autoExposureEV: 0)
        let back = try scanPipeline.process(dark, width: gB.width, height: gB.height, stochastic: false, edge: gB, autoExposureEV: 0)
        let rebate = 2 * gF.width + gF.width / 2, picture = (Int(gF.gate.minY) + 4) * gF.width + gF.width / 2
        precondition(front[rebate] == none[rebate] || abs((front[rebate] - none[rebate]).sum()) < 1e-6, "Front leak exposed the rebate")
        precondition(abs((front[picture] - none[picture]).sum()) > 0.01, "Front leak did not expose the picture")
        precondition(abs((back[rebate] - none[rebate]).sum()) > 0.01, "Back leak did not reach the rebate")
        let cool = FilmEdgeGeometry.light(neutral: RGB(1, 1, 1), warmth: -1), warmLight = FilmEdgeGeometry.light(neutral: RGB(1, 1, 1), warmth: 1)
        precondition(cool.z > cool.x && warmLight.x > warmLight.z, "Front/back light colours swapped")
        // RA-4 holder: a reflective carrier edge darkens a band inside the opening; aged tape lightens and cools the print.
        selection.manualType = .negativePrint
        var printRecipe = base; printRecipe.filmEdgeSelection = selection
        let printPipeline = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(printRecipe))
        func printed(_ d: FilmEdgeDistress) throws -> (FilmEdgeGeometry, [RGB]) {
            let g = geometry(d)
            let grey = Array(repeating: RGB(repeating: 0.12), count: g.width * g.height)
            return (g, try printPipeline.process(grey, width: g.width, height: g.height, stochastic: false, edge: g, autoExposureEV: 0))
        }
        let (_, plainPrint) = try printed(FilmEdgeDistress())
        var reflective = FilmEdgeDistress(); reflective.carrierReflection = 1
        let (gr, reflectedPrint) = try printed(reflective)
        let endPixel = (gr.height / 2) * gr.width + 1
        precondition((reflectedPrint[endPixel] - plainPrint[endPixel]).sum() < -0.002, "Carrier reflection did not darken the print edge")
        var taped = FilmEdgeDistress(); taped.tape = 1; taped.tapeAge = 1; taped.seed = 4
        let (gt, tapedPrint) = try printed(taped)
        var tapedIndex: Int?
        for y in 0..<gt.height { for x in 0..<gt.width where tapedIndex == nil {
            if gt.tapeTransmission(x: x, y: y).z < 0.7 && gt.supportCoverage(x: x, y: y) == 1 { tapedIndex = y * gt.width + x }
        }}
        precondition(tapedIndex != nil, "No taped intact film in the test frame")
        let tapeDelta = tapedPrint[tapedIndex!] - plainPrint[tapedIndex!]
        precondition(tapeDelta.sum() > 0.003 && tapeDelta.z > tapeDelta.x, "Aged tape did not print lighter and bluer: \(tapeDelta)")
        // Leak light enters as exposure: a negative print darkens nothing it should brighten, and
        // the warm path reaches the red-sensitive layer more than the blue.
        let neutral = RGB(1, 1, 1)
        var warm = FilmEdgeDistress(); warm.warmth = 1
        let light = geometry(warm).leakLight(neutral: neutral)
        precondition(light.x > 5 * light.z, "Base-path light did not favour the red-sensitive layer")
        print("PASS: distress CPU/Metal agreement incl. BH/released scratches (max \(maxError)), BH-1866 vs KS-1870 geometry, worn holes, perforation fog, gated front vs back leaks, carrier reflection and tape, rebate-clamped scratches, depth/route scratch colour, Amount 0 identity, stable seeded features, physical-size dust/carrier (\(dustSmall)/\(dustLarge) mm²), intact KS holes, 120 without sprockets, route-dependent dust polarity")
    }

    static func checkWorkflow(root: URL, recipe initial: EditRecipe) async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/spektrafilm-build/film-edge-proof")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 900, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 300, width: 900, height: 300))
        let source = context.makeImage()!
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, source, nil); precondition(CGImageDestinationFinalize(destination))
        let renderer = PhotoRenderer(source: source, directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"), data: encoded as Data)
        var recipe = initial
        recipe.filmEdgeSelection = nil
        recipe.flags["film_render.grain.active"] = false
        let started = ProcessInfo.processInfo.systemUptime
        for type in FilmEdgeType.allCases {
            var selection = FilmEdgeSelection(); selection.mode = .manual; selection.manualType = type
            recipe.filmEdgeSelection = selection
            let preview = try await renderer.renderFilmEdge(recipe, maximum: 720)
            precondition(max(preview.width, preview.height) == 720)
            let url = folder.appendingPathComponent(type.rawValue + ".png")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, preview, nil); precondition(CGImageDestinationFinalize(dest))
        }
        // Visual review: every preset on a negative print and a slide scan.
        for preset in FilmEdgeDistress.Preset.allCases {
            for type in [FilmEdgeType.negativePrint, .reversalScan] {
                var styled = recipe
                var selection = FilmEdgeSelection(); selection.mode = .manual; selection.manualType = type
                styled.filmEdgeSelection = selection
                styled.filmEdgeLayout?.distress.apply(preset)
                let image = try await renderer.renderFilmEdge(styled, maximum: 1080)
                let url = folder.appendingPathComponent("distress-\(preset.rawValue)-\(type.rawValue).png")
                let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, image, nil); precondition(CGImageDestinationFinalize(dest))
            }
        }
        var tilted = recipe
        tilted.filmEdgeLayout?.distress.apply(.worn); tilted.look.enabled = false
        _ = try await renderer.renderFilmEdge(tilted, maximum: 512)  // creative centre + tilted gate mask
        recipe.filmEdgeSelection = nil
        recipe.flags["camera.auto_exposure"] = true
        var paper = PrintLayout(); paper.paper = .eightByTen; paper.scale = 0.75
        recipe.printLayout = paper
        recipe.tone.monochrome = true
        let restored = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        precondition(restored == recipe)
        let preview = try await renderer.renderPresentation(restored, maximum: 1080)
        let (url, w, h) = try await renderer.export(restored, size: .small, format: .png, quality: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let exported = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
        precondition(w == 900 && h == 720 && preview.width == w && preview.height == h,
            "Finishing silently increased native dimensions or lost the paper shape")
        let a = try PhotoColorBridge.decode(preview), b = try PhotoColorBridge.decode(exported)
        precondition(a.count == b.count)
        for i in a.indices {
            precondition(abs(a[i].x - b[i].x) < 0.005 && abs(a[i].y - b[i].y) < 0.005 && abs(a[i].z - b[i].z) < 0.005,
                "Saved presentation and PNG export diverged")
            precondition(abs(b[i].x - b[i].y) < 0.002 && abs(b[i].x - b[i].z) < 0.002, "B&W did not include the edge")
        }
        precondition(b[0].x > 0.99, "Paper inherited edge density or table shadows")
        // Cancellation cannot publish a file or leave the serial worker unusable.
        let cancelled = Task { try await renderer.renderFilmEdge(recipe, maximum: 720) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled edge work completed") } catch is CancellationError {}
        _ = try await renderer.renderFilmEdge(recipe, maximum: 256)
        let proof = folder.appendingPathComponent("paper-bw.png")
        try? FileManager.default.removeItem(at: proof)
        try FileManager.default.copyItem(at: url, to: proof)
        // The batch worker consumes the same durable recipe from original bytes.
        let original = folder.appendingPathComponent("source.png")
        try (encoded as Data).write(to: original)
        let resources = FilmRenderResources(directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"))
        let batch = BatchPhotoExporter(directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"),
            luts: folder, resources: resources)
        let item = BatchExportItem(id: UUID(), name: "source.png", source: original, recipe: restored, width: 900, height: 600)
        let batchURL = try await batch.export(item, size: .small, format: .png, quality: 1)
        defer { try? FileManager.default.removeItem(at: batchURL) }
        let batchImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(batchURL as CFURL, nil)!, 0, nil)!
        let c = try PhotoColorBridge.decode(batchImage)
        precondition(c == b, "Batch finishing differed from the editor export")
        // Old adaptive recipes are cropped to the physical gate at every rendering entry.
        recipe.geometry.quarterTurns = 1
        recipe.crop.normalizedRect = CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
        recipe.printLayout = nil
        recipe.filmEdgeLayout?.format = .roll120
        let rotated = try await renderer.renderPresentation(recipe, maximum: 720)
        recipe.constrainFilmEdgeCrop(imageSize: CGSize(width: 900, height: 600))
        let fixedCrop = recipe.crop.pixelRect(in: CGSize(width: 600, height: 900))
        let expected = FilmEdgeGeometry(imageSize: recipe.crop.pixelRect(in: CGSize(width: 600, height: 900)).size,
            layout: recipe.filmEdgeLayout!, longEdge: Int(max(fixedCrop.width, fixedCrop.height)))!
        precondition(rotated.width == expected.width && rotated.height == expected.height)
        recipe.look.enabled = false
        _ = try await renderer.renderFilmEdge(recipe, maximum: 256)
        recipe.look.enabled = true; recipe.look.mode = .lut
        _ = try await renderer.renderFilmEdge(recipe, maximum: 256)
        let largeContext = CGContext(data: nil, width: 2160, height: 1440, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        largeContext.draw(source, in: CGRect(x: 0, y: 0, width: 2160, height: 1440))
        let large = PhotoRenderer(source: largeContext.makeImage()!, directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"))
        var settled = initial
        settled.filmEdgeSelection = nil; settled.filmEdgeLayout = FilmEdgeLayout()
        settled.look.enabled = true; settled.look.mode = .spektrafilm; settled.mix = 1
        let previewStart = ProcessInfo.processInfo.systemUptime
        _ = try await large.renderFilmEdge(settled, maximum: 720)
        let quickMS = (ProcessInfo.processInfo.systemUptime - previewStart) * 1000
        let refineStart = ProcessInfo.processInfo.systemUptime
        let refined = try await large.renderFilmEdge(settled, maximum: 2160)
        precondition(refined.width == 2160 && refined.height == 1517)
        let refineMS = (ProcessInfo.processInfo.systemUptime - refineStart) * 1000
        do {
            _ = try await large.export(settled, size: .full, format: .png, quality: 1)
            preconditionFailure("Edge export silently substituted a preview when original bytes were missing")
        } catch PhotoExporter.Failure.decode {}
        print("PASS: grain-enabled 720→2160 full-support refinement. Quick ms \(quickMS), settled ms \(refineMS); no silent resolution reduction")
        print("PASS: real source → four families → saved recipe → paper/B&W → matching PNG export; cancellation recovery; native output bounded. Workflow \((ProcessInfo.processInfo.systemUptime - started) * 1000) ms; proof PNGs \(folder.path)")
    }
}
