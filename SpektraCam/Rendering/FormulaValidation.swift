#if DEBUG && targetEnvironment(simulator)
import CoreImage
import CryptoKit
import Foundation
import UIKit

/// Explicit regression checks in the isolated UI-test library, using the actual renderer and
/// editor. They cannot run against the user's library or change a device's preferences.
@MainActor enum FormulaValidation {
    static func run(_ library: PhotoLibrary) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-test-library"), let option = args.firstIndex(of: "--check-formulae"),
              option + 1 < args.count else { return }
        let reportURL = URL(fileURLWithPath: args[option + 1])
        var checks: [String] = []
        do {
            try await check(library, checks: &checks)
            try JSONSerialization.data(withJSONObject: ["result": "PASS", "checks": checks], options: [.prettyPrinted])
                .write(to: reportURL, options: .atomic)
        } catch {
            try? JSONSerialization.data(withJSONObject: ["result": "FAIL", "error": String(describing: error), "checks": checks])
                .write(to: reportURL, options: .atomic)
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "FormulaRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private static func check(_ library: PhotoLibrary, checks: inout [String]) async throws {
        try require(library.photos.count >= 2, "Two different photos are required")
        let photos = Array(library.photos.prefix(2))
        let originals = try photos.map { try Data(contentsOf: library.files.sourceURL($0)) }
        var first = EditRecipe()
        first.filmID = "fujifilm_c200"
        first.printID = "fujifilm_crystal_archive_typeii"
        first.flags["film_render.grain.active"] = false
        first.flags["film_render.halation.active"] = false
        first.tone.contrast = 1.15
        first.source.warmth = 12
        first.tone.exposureEV = 0.5
        first.numbers["enlarger.y_filter_shift"] = 7
        first.removeDefaultOverrides()
        let firstFormula = try Formula(name: "First saved", parts: [.look, .exposure], from: first, luts: [])
        try await library.formulae.save(firstFormula)
        var second = first
        second.filmID = "kodak_portra_400"
        second.tone.monochrome = true
        second.tone.contrast = 0.85
        let secondFormula = try Formula(name: "Later saved", parts: [.look], from: second, luts: [])
        try await library.formulae.save(secondFormula)
        let files = try library.formulae.items.map { try Data(contentsOf: library.formulae.fileURL($0.id)) }
        let recipes = [firstFormula.id: firstFormula.recipe, secondFormula.id: secondFormula.recipe]
        checks.append("first and later formula files round-trip")

        for photo in photos {
            let imported = try await library.files.decodedPhoto(photo, maximum: 192)
            let warm = PhotoRenderer(source: imported.preview, directory: Bundle.main.resourceURL!, data: imported.data,
                temperature: imported.rawTemperature, previewMaximum: 192, resources: library.images.resources,
                sourceType: imported.sourceType, description: imported.sourceDescription)
            // A different target has its own exposure, WB, LUT mode, crop and manual overrides.
            var target = EditorDefaults.originalRecipe(temperature: imported.rawTemperature)
            target.look.mode = .lut
            target.tone.exposureEV = -0.6
            target.source.warmth = -20
            target.numbers["enlarger.y_filter_shift"] = -8
            for formulaID in [firstFormula.id, secondFormula.id, firstFormula.id] {
                library.queueRecipe(target, for: photo.id)
                try library.flushPending()
                let formula = library.formulae.formula(formulaID)!
                _ = try await library.applyFormula(formula, to: [photo.id])
                let applied = try library.recipe(photo.id)!
                try require(applied.filmID == formula.recipe.filmID && applied.tone.contrast == formula.recipe.tone.contrast,
                    "A formula retained the target's film or tone")
                if formula.parts.contains(.exposure) {
                    try require(applied.source.warmth == first.source.warmth && applied.tone.exposureEV == first.tone.exposureEV
                        && applied.number("enlarger.y_filter_shift") == 7, "Full formula changed with the target's exposure")
                } else {
                    try require(applied.source.warmth == target.source.warmth && applied.tone.exposureEV == target.tone.exposureEV
                        && applied.number("enlarger.y_filter_shift") == -8, "Look-only formula replaced the target's exposure")
                }
                let session = EditorSession(photo: imported, recipe: target, luts: library.luts, resources: library.images.resources)
                session.update(key: "formula.apply") {
                    $0 = $0.taking(Set(formula.parts), from: formula.recipe, rawTarget: photo.isRAW)
                }
                try require(session.recipe == applied, "Viewer and editor applied different settings")
                session.cancelRendering()
                let actual = try await warm.render(applied, maximum: 192)
                let cold = PhotoRenderer(source: imported.preview, directory: Bundle.main.resourceURL!, data: imported.data,
                    temperature: imported.rawTemperature, previewMaximum: 192,
                    sourceType: imported.sourceType, description: imported.sourceDescription)
                let expected = try await cold.render(applied, maximum: 192)
                try require(maxError(actual, expected) <= 1.1 / 255, "Warm formula renderer differs from a fresh renderer")
                try require(library.formulae.formula(formulaID)?.recipe == recipes[formulaID], "Applying mutated a saved formula")
            }
            checks.append("viewer/editor and warm/fresh pixels: " + photo.filename)
        }
        try await library.formulae.load()
        let after = try library.formulae.items.map { try Data(contentsOf: library.formulae.fileURL($0.id)) }
        try require(files == after, "Applying or editing rewrote a formula file")
        checks.append("formula bytes unchanged after A/B/A application and reload")

        // A RAW export must be byte-identical. This deliberately needs no RAW decoder.
        let raw = OriginalRAWExporter(data: originals[0], filename: "capture.dng", type: "com.adobe.raw-image", width: 97, height: 65)
        let (copy, _, _) = try await raw.export()
        try require(try Data(contentsOf: copy) == originals[0] && copy.lastPathComponent == "capture.dng", "RAW export changed bytes or filename")
        await raw.discard()
        for (index, photo) in photos.enumerated() {
            try require(try Data(contentsOf: library.files.sourceURL(photo)) == originals[index], "Source bytes changed")
        }
        checks.append("original RAW bytes and filename preserved; source files unchanged")

        let imported = try await library.files.decodedPhoto(photos[0], maximum: 192)
        let renderer = PhotoRenderer(source: imported.preview, directory: Bundle.main.resourceURL!, data: imported.data,
            temperature: imported.rawTemperature, previewMaximum: 192, sourceType: imported.sourceType, description: imported.sourceDescription)
        var bordered = first
        bordered.filmEdgeLayout = FilmEdgeLayout.newDefault()
        bordered.filmEdgeSelection = FilmEdgeSelection()
        bordered.tone.highlights = -0.5
        bordered.tone.contrast = 0.8
        bordered.constrainFilmEdgeCrop(imageSize: CGSize(width: imported.width, height: imported.height))
        let edge = try await renderer.renderFilmEdge(bordered, maximum: 192)
        let corner = PrintCompositor.paperTone(of: edge).components!
        try require(corner.prefix(3).allSatisfy { $0 >= 254.0 / 255 }, "Covered paper was toned down")
        // Region finishing must match the same full-canvas mask, including regions fully
        // outside the opening and crops on each of its four sides.
        let layout = bordered.renderedFilmEdgeLayout!
        let crop = bordered.crop.pixelRect(in: CGSize(width: imported.width, height: imported.height))
        guard let geometry = FilmEdgeGeometry(imageSize: crop.size, layout: layout, longEdge: 192) else {
            throw PhotoExporter.Failure.render
        }
        for rect in [CGRect(x: 0, y: 0, width: 3, height: geometry.height),
                     CGRect(x: geometry.width - 3, y: 0, width: 3, height: geometry.height)] {
            let patch = edge.cropping(to: rect)!
            let finished = try FilmEdgeRenderer.restoringPaper(patch, geometry: geometry, origin: (Int(rect.minX), 0))
            try require(finished.width == 3, "Region finishing failed")
        }
        checks.append("covered paper stays white after tone; narrow loupe regions finish safely")
    }

    private static func maxError(_ a: CGImage, _ b: CGImage) -> Float {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.cacheIntermediates: false])
        func pixels(_ image: CGImage) -> [Float] {
            var values = [Float](repeating: 0, count: image.width * image.height * 4)
            values.withUnsafeMutableBytes {
                context.render(CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: image.width * 16,
                    bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBAf, colorSpace: space)
            }
            return values
        }
        return zip(pixels(a), pixels(b)).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }
}
#endif
