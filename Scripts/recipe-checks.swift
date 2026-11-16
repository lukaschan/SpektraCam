import Foundation

@main struct RecipeChecks {
    static func main() throws {
        var neutral = EditRecipe()
        neutral.look.enabled = false
        let savedNeutral = try JSONEncoder().encode(neutral)
        let decodedNeutral = try JSONDecoder().decode(EditRecipe.self, from: savedNeutral)
        precondition(decodedNeutral.look.enabled == false)
        var legacy = try JSONSerialization.jsonObject(with: savedNeutral) as! [String: Any]
        var look = legacy["look"] as! [String: Any]
        look.removeValue(forKey: "enabled")
        legacy["look"] = look
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let decodedLegacy = try JSONDecoder().decode(EditRecipe.self, from: legacyData)
        precondition(decodedLegacy.look.enabled,
            "An existing saved look must remain active")
        let all = ParameterDefinition.catalog
        precondition(Set(all.map(\.id)).count == all.count, "Duplicate parameter path")
        for field in all {
            if let value = field.defaultNumber {
                precondition(value.isFinite && field.step > 0)
                precondition(field.sliderRange.contains(value), "Default outside slider: " + field.id)
                precondition(
                    field.minimum.map { field.sliderRange.lowerBound >= $0 } ?? true,
                    "Slider below minimum: " + field.id)
                precondition(
                    field.maximum.map { field.sliderRange.upperBound <= $0 } ?? true,
                    "Slider above maximum: " + field.id)
            }
        }
        var recipe = EditRecipe()
        recipe.numbers["camera.exposure_compensation_ev"] = -2.25
        recipe.flags["film_render.grain.active"] = false
        recipe.numbers["film_render.grain.particle_area_um2"] = 0.8
        recipe.geometry.rotateLeft()
        recipe.crop.setAspect(.cinemaScope, imageAspect: 1.5)
        let processing = recipe.processingRecipe
        recipe.geometry.rotateLeft()
        recipe.crop = CropSelection()
        precondition(recipe.processingRecipe == processing, "Geometry invalidated film processing")
        recipe.temperature = 5600
        let portra = FilmStock.films.first { $0.id == "kodak_portra_400" }!
        let provia = FilmStock.films.first { $0.id == "fujifilm_provia_100f" }!
        let cinema = FilmStock.films.first { $0.id == "kodak_vision3_500t" }!
        var transition = EditRecipe()
        transition.printID = "kodak_2393"
        transition.selectFilm(provia)
        precondition(transition.scanFilm && transition.printID == "kodak_2393")
        transition.selectFilm(portra)
        precondition(
            !transition.scanFilm && transition.printID == "kodak_2393",
            "Reversal → negative retained direct scan or lost chosen print")
        transition.scanFilm = true
        transition.selectFilm(portra)
        precondition(transition.scanFilm, "Tapping the selected stock erased the explicit route")
        transition.selectFilm(cinema)
        precondition(!transition.scanFilm && cinema.category == .cinemaNegative)
        precondition(provia.category == .reversal && portra.category == .photoNegative)
        precondition(FilmStock.films.allSatisfy { FilmStock.Category.films.contains($0.category) })
        precondition(FilmStock.prints.allSatisfy { FilmStock.Category.prints.contains($0.category) })
        precondition(FilmStock.prints.filter { $0.category == .cinemaPrint }.count == 2)
        for ev in [-3.0, -1, 0, 1, 3] {
            transition.printExposureEV = ev
            precondition(abs(transition.number("enlarger.print_exposure") - pow(2, ev)) < 1e-12)
            precondition(abs(transition.printExposureEV - ev) < 1e-12)
        }
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        precondition(decoded == recipe)
        precondition(!recipe.flag("film_render.grain.active"))
        precondition(recipe.number("film_render.grain.particle_area_um2") == 0.8)
        precondition(FilmStock.films.count == 20 && FilmStock.prints.count == 8)
        recipe.filmID = "fujifilm_provia_100f"
        recipe.scanFilm = true
        precondition(recipe.bypassesPrint)
        recipe.scanFilm = false
        precondition(!recipe.bypassesPrint, "Scan/print is an explicit route")
        precondition(EditRecipe().number("film_render.halation.halation_strength[0]") == 0.015)
        recipe.filmID = "kodak_gold_200"
        precondition(recipe.number("film_render.halation.halation_strength[0]") == 0.08)
        recipe.numbers["camera.exposure_compensation_ev"] = 0
        recipe.removeDefaultOverrides()
        precondition(recipe.numbers["camera.exposure_compensation_ev"] == nil)
        try checkParts()
        print(
            "PASS: \(all.count) parameter components, physical UI bounds, stock routes, retained values, recipe round-trip and parts"
        )
    }

    /// A pasted part replaces that part and nothing else, whatever the target held before.
    static func checkParts() throws {
        typealias Part = EditRecipe.Part
        var source = EditRecipe()
        source.filmID = "kodak_gold_200"
        source.printID = "kodak_2393"
        source.look.mode = .lut
        source.look.first.id = String(repeating: "a", count: 64)
        source.tone.contrast = 1.2
        source.tone.exposureEV = 0.7
        source.tone.monochrome = true
        source.monochromeGrain = true
        source.mix = 0.5
        source.source = .init(exposureEV: 0.3, warmth: 12, tint: -4, saturation: 0.8)
        source.temperature = 4800
        source.numbers["film_render.grain.particle_area_um2"] = 0.8
        source.numbers["camera.exposure_compensation_ev"] = 1.5
        source.numbers["enlarger.y_filter_shift"] = 9
        source.numbers["enlarger.m_filter_shift"] = -6
        source.printExposureEV = 0.5
        source.flags["camera.auto_exposure"] = false
        source.choices["enlarger.illuminant"] = "x"
        var paper = PrintLayout()
        paper.paper = .eightByTen
        source.printLayout = paper
        source.filmEdgeSelection = FilmEdgeSelection()
        source.filmEdgeLayout = FilmEdgeLayout()
        source.geometry.rotateLeft()
        source.crop.setAspect(.cinemaScope, imageAspect: 1.5)

        var target = EditRecipe()
        target.filmID = "fujifilm_provia_100f"
        target.tone.exposureEV = -1
        target.tone.shadows = 0.4
        target.source.tint = 3
        target.temperature = 6100
        target.numbers["film_render.grain.particle_area_um2"] = 0.3
        target.numbers["film_render.halation.scatter_amount"] = 0.9  // Must not survive a new Look.
        target.numbers["enlarger.y_filter_shift"] = 2
        target.flags["film_render.grain.active"] = false
        target.geometry.rotateLeft()
        target.geometry.rotateLeft()
        target.crop.setAspect(.square, imageAspect: 1.5)

        precondition(target.taking([], from: source, rawTarget: true) == target, "No part changed the photo")

        let look = target.taking([.look], from: source, rawTarget: true)
        precondition(look.filmID == source.filmID && look.printID == source.printID && look.look == source.look)
        precondition(look.tone.contrast == 1.2 && look.tone.monochrome && look.tone.shadows == 0)
        precondition(look.tone.exposureEV == -1, "Look replaced the photo's exposure")
        precondition(look.source.saturation == 0.8 && look.source.tint == 3 && look.source.warmth == 0)
        precondition(look.temperature == 6100)
        precondition(look.numbers["film_render.grain.particle_area_um2"] == 0.8)
        precondition(look.numbers["film_render.halation.scatter_amount"] == nil, "The old look's override leaked")
        precondition(look.numbers["enlarger.y_filter_shift"] == 2, "Look replaced the photo's filter pack")
        precondition(look.numbers["camera.exposure_compensation_ev"] == nil)
        precondition(look.flags == source.flags && look.choices == source.choices)
        precondition(look.monochromeGrain && look.mix == 0.5)
        precondition(look.printLayout == nil && look.filmEdgeLayout == nil, "Look carried the Darkroom")
        precondition(look.crop == target.crop && look.geometry == target.geometry, "Look moved the framing")

        let exposure = target.taking([.exposure], from: source, rawTarget: true)
        precondition(exposure.filmID == target.filmID && exposure.look == target.look)
        precondition(exposure.tone.exposureEV == 0.7 && exposure.tone.shadows == 0.4)
        precondition(exposure.source.exposureEV == 0.3 && exposure.source.warmth == 12 && exposure.source.tint == -4)
        precondition(exposure.source.saturation == 1, "Saturation belongs to the Look")
        precondition(exposure.temperature == 4800)
        precondition(target.taking([.exposure], from: source, rawTarget: false).temperature == 6100,
            "A RAW white balance reached a rendered photo")
        precondition(exposure.numbers["camera.exposure_compensation_ev"] == 1.5)
        precondition(exposure.numbers["enlarger.y_filter_shift"] == 9 && exposure.numbers["enlarger.m_filter_shift"] == -6)
        precondition(abs(exposure.printExposureEV - 0.5) < 1e-12)
        precondition(exposure.numbers["film_render.grain.particle_area_um2"] == 0.3)
        precondition(exposure.numbers["film_render.halation.scatter_amount"] == 0.9)
        precondition(exposure.flags == target.flags)

        let darkroom = target.taking([.darkroom], from: source, rawTarget: true)
        precondition(darkroom.printLayout == source.printLayout && darkroom.filmEdgeLayout == source.filmEdgeLayout)
        precondition(darkroom.filmEdgeSelection == source.filmEdgeSelection)
        precondition(darkroom.processingRecipe == target.processingRecipe, "Darkroom changed the film render")
        precondition(darkroom.crop == target.crop && darkroom.geometry == target.geometry)

        // All parts together are the source with the target's framing.
        var expected = source
        expected.crop = target.crop
        expected.geometry = target.geometry
        expected.removeDefaultOverrides()
        precondition(target.taking(Set(Part.allCases), from: source, rawTarget: true) == expected)
        // The three parts are independent: any order gives the same result.
        let stepwise = target.taking([.darkroom], from: source, rawTarget: true)
            .taking([.exposure], from: source, rawTarget: true).taking([.look], from: source, rawTarget: true)
        precondition(stepwise == expected, "Parts overlap")

        precondition(EditRecipe().has(.look) && !EditRecipe().has(.exposure) && !EditRecipe().has(.darkroom))
        precondition(source.has(.exposure) && source.has(.darkroom))
        var balanced = EditRecipe()
        balanced.numbers["enlarger.m_filter_shift"] = 4
        precondition(balanced.has(.exposure), "The filter pack stays with the photo")
        let clip = LookClip(source)
        precondition(clip.recipe.crop == CropSelection() && clip.recipe.geometry.isIdentity, "A clip kept framing")
        precondition(clip.parts == Part.allCases)
        precondition(clip.removingLUTs(source.look.identifiers).recipe.look.first.id == nil)
    }
}
