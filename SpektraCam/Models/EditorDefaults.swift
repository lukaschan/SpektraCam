import Foundation

/// Preferences seed new edits; saved recipes and the reference model keep their own values.
nonisolated enum EditorDefaults {
    static let halationKey = "editor.default.halation"
    static let grainKey = "editor.default.grain"
    static let monochromeGrainKey = "editor.default.monochromeGrain"

    private static func flag(_ key: String, fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
    static func originalRecipe(temperature: Double?) -> EditRecipe {
        var recipe = EditRecipe()
        recipe.look.enabled = false
        recipe.temperature = temperature
        recipe.flags["film_render.halation.active"] = flag(halationKey, fallback: true)
        recipe.flags["film_render.grain.active"] = flag(grainKey, fallback: true)
        recipe.monochromeGrain = flag(monochromeGrainKey, fallback: false)
        recipe.removeDefaultOverrides()
        return recipe
    }
}
