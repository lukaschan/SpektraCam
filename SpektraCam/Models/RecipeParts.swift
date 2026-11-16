import CoreGraphics
import Foundation

/// The parts of an edit that can travel from one photo to another. They follow the process:
/// the Look is the film, print and effects; Exposure is what was corrected for one negative;
/// Darkroom is the paper and film edge. Crop and rotation belong to the photograph and
/// never travel.
nonisolated extension EditRecipe {
    enum Part: String, Codable, CaseIterable, Identifiable, Sendable {
        case look, exposure, darkroom
        var id: Self { self }
        var title: String {
            switch self {
            case .look: String(localized: "part.look", defaultValue: "Look")
            case .exposure: String(localized: "part.exposure", defaultValue: "Exposure")
            case .darkroom: String(localized: "part.darkroom", defaultValue: "Darkroom")
            }
        }
        var detail: String {
            switch self {
            case .look:
                String(localized: "part.look.detail", defaultValue: "Film, print, contrast, color and effects")
            case .exposure:
                String(
                    localized: "part.exposure.detail",
                    defaultValue: "Exposure, white balance and print balance")
            case .darkroom:
                String(localized: "part.darkroom.detail", defaultValue: "Paper, border and film edge")
            }
        }
    }

    /// Physical parameters corrected for one photo: how much light, and the filter pack that
    /// balanced this negative. Every other parameter is part of the Look, including whether
    /// exposure is metered automatically.
    static let exposureNumbers: Set<String> = [
        "camera.exposure_compensation_ev", "enlarger.print_exposure",
        "enlarger.y_filter_shift", "enlarger.m_filter_shift",
    ]

    /// This recipe with the chosen parts replaced by `source`'s. A part is replaced whole:
    /// parameters hold only overrides of the stock's defaults, so a merge would leave the
    /// old look's overrides behind. Parts not chosen are untouched.
    ///
    /// The switch has no default on purpose. A new stored field does not compile until it
    /// is given to a part here, so later Darkroom settings cannot be left out by accident.
    func taking(_ parts: Set<Part>, from source: EditRecipe, rawTarget: Bool) -> EditRecipe {
        let look = parts.contains(.look)
        let exposure = parts.contains(.exposure)
        let darkroom = parts.contains(.darkroom)
        var result = self
        for key in CodingKeys.allCases {
            switch key {
            case .look: if look { result.look = source.look }
            case .filmID: if look { result.filmID = source.filmID }
            case .printID: if look { result.printID = source.printID }
            case .scanFilm: if look { result.scanFilm = source.scanFilm }
            case .mix: if look { result.mix = source.mix }
            case .monochromeGrain: if look { result.monochromeGrain = source.monochromeGrain }
            case .flags: if look { result.flags = source.flags }
            case .choices: if look { result.choices = source.choices }
            case .tone:
                let stops = (exposure ? source : self).tone.exposureEV
                if look { result.tone = source.tone }
                result.tone.exposureEV = stops
            case .source:
                if look { result.source.saturation = source.source.saturation }
                if exposure {
                    result.source.exposureEV = source.source.exposureEV
                    result.source.warmth = source.source.warmth
                    result.source.tint = source.source.tint
                }
            case .temperature:
                // A RAW white balance means nothing to a rendered file, and the reverse.
                if exposure, rawTarget, let kelvin = source.temperature { result.temperature = kelvin }
            case .numbers:
                let lookNumbers = (look ? source : self).numbers.filter {
                    !Self.exposureNumbers.contains($0.key)
                }
                let exposureNumbers = (exposure ? source : self).numbers.filter {
                    Self.exposureNumbers.contains($0.key)
                }
                result.numbers = lookNumbers.merging(exposureNumbers) { _, new in new }
            case .printLayout: if darkroom { result.printLayout = source.printLayout }
            case .filmEdgeSelection:
                if darkroom { result.filmEdgeSelection = source.filmEdgeSelection }
            case .filmEdgeLayout: if darkroom { result.filmEdgeLayout = source.filmEdgeLayout }
            case .crop, .geometry: break  // The photograph's own framing.
            case .version, .upstreamRevision: break  // The caller pastes within one film model.
            }
        }
        result.removeDefaultOverrides()
        return result
    }

    /// Whether a part holds anything, so an empty part is not offered for pasting.
    func has(_ part: Part) -> Bool {
        switch part {
        case .look: true
        case .exposure: taking([.exposure], from: EditRecipe(), rawTarget: false) != self
        case .darkroom: printLayout != nil || filmEdgeLayout != nil || filmEdgeSelection != nil
        }
    }
}

/// A copied look: one whole recipe without its framing. A saved Formula will be this with a name.
nonisolated struct LookClip: Equatable, Sendable {
    let recipe: EditRecipe
    /// The library photo it was copied from, for showing where the look came from.
    let sourceID: UUID?

    init(_ recipe: EditRecipe, sourceID: UUID? = nil) {
        var copy = recipe
        copy.crop = CropSelection()
        copy.geometry = ImageGeometry()
        self.recipe = copy
        self.sourceID = sourceID
    }
    var parts: [EditRecipe.Part] { EditRecipe.Part.allCases.filter { recipe.has($0) } }
    func removingLUTs(_ ids: Set<String>) -> Self { Self(recipe.removingLUTs(ids), sourceID: sourceID) }
}
