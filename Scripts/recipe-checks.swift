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
        print(
            "PASS: \(all.count) parameter components, physical UI bounds, stock routes, retained values and recipe round-trip"
        )
    }
}
