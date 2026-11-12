import Foundation

/// Edge appearance is a choice, independent of capture format and final monochrome output.
nonisolated enum FilmEdgeType: String, Codable, CaseIterable, Sendable {
    case negativePrint
    case negativeScan
    case reversalScan
    case cinemaPrint
    var title: String {
        switch self {
        case .negativePrint: String(localized: "darkroom.edge.negative_print", defaultValue: "Negative print")
        case .negativeScan: String(localized: "darkroom.edge.negative_scan", defaultValue: "Negative scan")
        case .reversalScan: String(localized: "darkroom.edge.slide_scan", defaultValue: "Slide scan")
        case .cinemaPrint: String(localized: "darkroom.edge.cinema_print", defaultValue: "Cinema print film")
        }
    }
}

/// Auto follows Develop; returning to Manual restores the user's last explicit choice.
/// This preference does not enable an edge or change the photograph's Develop settings.
nonisolated struct FilmEdgeSelection: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case automatic, manual }
    var mode = Mode.automatic
    var manualType = FilmEdgeType.negativePrint

    init() {}
    enum CodingKeys: String, CodingKey { case mode, manualType }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .automatic
        manualType = try values.decodeIfPresent(FilmEdgeType.self, forKey: .manualType) ?? .negativePrint
    }

    func resolvedType(for recipe: EditRecipe) -> FilmEdgeType {
        if mode == .manual { return manualType }
        // An arbitrary LUT has no identifiable film route; use the ordinary print family.
        guard recipe.look.mode == .spektrafilm else { return .negativePrint }
        if recipe.scanFilm {
            let film = FilmStock.films.first { $0.id == recipe.filmID }
            return film?.isPositive == true ? .reversalScan : .negativeScan
        }
        let print = FilmStock.prints.first { $0.id == recipe.printID }
        return print?.support == "film" ? .cinemaPrint : .negativePrint
    }
}
