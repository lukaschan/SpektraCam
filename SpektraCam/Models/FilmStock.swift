// Profile identifiers from spektrafilm 3bb2c2d. Andrea Volpato.
// Profile data: CC BY-SA 4.0; see SPEKTRAFILM_LICENSE.txt.
// Display names use SpektraCam aliases; upstream data and stable IDs are preserved.
import Foundation

nonisolated struct FilmStock: Identifiable, Sendable {
    let id: String
    /// User-facing alias, shared by visible labels and accessibility.
    let name: String
    let kind: String
    let support: String
    let stage: String
    let targetPrint: String?
    var defaults: [String: Double] { StockDefaults.numbers[id] ?? [:] }
    var isPositive: Bool { kind == "positive" }
    static let all: [FilmStock] = [
        .init(
            id: "fujifilm_c200", name: "F·C200", kind: "negative", support: "film",
            stage: "filming", targetPrint: "fujifilm_crystal_archive_typeii"),
        .init(
            id: "fujifilm_crystal_archive_typeii", name: "F·CA II",
            kind: "negative", support: "paper", stage: "printing", targetPrint: nil),
        .init(
            id: "fujifilm_pro_400h", name: "F·400H", kind: "negative", support: "film",
            stage: "filming", targetPrint: "fujifilm_crystal_archive_typeii"),
        .init(
            id: "fujifilm_provia_100f", name: "F·RDP III", kind: "positive",
            support: "film", stage: "filming", targetPrint: nil),
        .init(
            id: "fujifilm_velvia_100", name: "F·RVP100", kind: "positive",
            support: "film", stage: "filming", targetPrint: nil),
        .init(
            id: "fujifilm_xtra_400", name: "F·X400", kind: "negative", support: "film",
            stage: "filming", targetPrint: "fujifilm_crystal_archive_typeii"),
        .init(
            id: "kodak_2383", name: "K·2383", kind: "negative", support: "film",
            stage: "printing", targetPrint: nil),
        .init(
            id: "kodak_2393", name: "K·2393", kind: "negative", support: "film",
            stage: "printing", targetPrint: nil),
        .init(
            id: "kodak_ektachrome_100", name: "K·E100", kind: "positive",
            support: "film", stage: "filming", targetPrint: nil),
        .init(
            id: "kodak_ektacolor_edge", name: "K·EE", kind: "negative",
            support: "paper", stage: "printing", targetPrint: nil),
        .init(
            id: "kodak_ektar_100", name: "K·EK100", kind: "negative", support: "film",
            stage: "filming", targetPrint: "kodak_portra_endura"),
        .init(
            id: "kodak_endura_premier", name: "K·EP", kind: "negative",
            support: "paper", stage: "printing", targetPrint: nil),
        .init(
            id: "kodak_gold_200", name: "K·G200", kind: "negative", support: "film",
            stage: "filming", targetPrint: "kodak_portra_endura"),
        .init(
            id: "kodak_kodachrome_64", name: "K·K64", kind: "positive",
            support: "film", stage: "filming", targetPrint: nil),
        .init(
            id: "kodak_portra_160", name: "K·P160", kind: "negative", support: "film",
            stage: "filming", targetPrint: "kodak_portra_endura"),
        .init(
            id: "kodak_portra_400", name: "K·P400", kind: "negative", support: "film",
            stage: "filming", targetPrint: "kodak_portra_endura"),
        .init(
            id: "kodak_portra_800", name: "K·P800", kind: "negative", support: "film",
            stage: "filming", targetPrint: "kodak_portra_endura"),
        .init(
            id: "kodak_portra_800_push1", name: "K·P800 +1", kind: "negative",
            support: "film", stage: "filming", targetPrint: "kodak_portra_endura"),
        .init(
            id: "kodak_portra_800_push2", name: "K·P800 +2", kind: "negative",
            support: "film", stage: "filming", targetPrint: "kodak_portra_endura"),
        .init(
            id: "kodak_portra_endura", name: "K·PE", kind: "negative",
            support: "paper", stage: "printing", targetPrint: nil),
        .init(
            id: "kodak_supra_endura", name: "K·SE", kind: "negative",
            support: "paper", stage: "printing", targetPrint: nil),
        .init(
            id: "kodak_ultra_endura", name: "K·UE", kind: "negative",
            support: "paper", stage: "printing", targetPrint: nil),
        .init(
            id: "kodak_ultramax_400", name: "K·U400", kind: "negative", support: "film",
            stage: "filming", targetPrint: "kodak_portra_endura"),
        .init(
            id: "kodak_verita_200d", name: "K·5206 200D", kind: "negative", support: "film",
            stage: "filming", targetPrint: "kodak_2383"),
        .init(
            id: "kodak_vision3_200t", name: "K·5213 200T", kind: "negative", support: "film",
            stage: "filming", targetPrint: "kodak_2383"),
        .init(
            id: "kodak_vision3_250d", name: "K·5207 250D", kind: "negative", support: "film",
            stage: "filming", targetPrint: "kodak_2383"),
        .init(
            id: "kodak_vision3_500t", name: "K·5219 500T", kind: "negative", support: "film",
            stage: "filming", targetPrint: "kodak_2383"),
        .init(
            id: "kodak_vision3_50d", name: "K·5203 50D", kind: "negative", support: "film",
            stage: "filming", targetPrint: "kodak_2383"),
    ]
    static let films = all.filter { $0.stage == "filming" }
    static let prints = all.filter { $0.stage == "printing" }

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case photoNegative, cinemaNegative, reversal, photoPaper, cinemaPrint
        var id: Self { self }
        var shortTitle: String {
            switch self {
            case .photoNegative: String(localized: "film_stock.photo", defaultValue: "Photo")
            case .cinemaNegative: String(localized: "film_stock.cine", defaultValue: "Cine")
            case .reversal: String(localized: "film_stock.slide", defaultValue: "Slide")
            case .photoPaper: String(localized: "film_stock.paper", defaultValue: "Paper")
            case .cinemaPrint: String(localized: "film_stock.film", defaultValue: "Film")
            }
        }
        var title: String {
            switch self {
            case .photoNegative:
                String(
                    localized: "film_stock.color_negative_photo",
                    defaultValue: "Color negative · Photo")
            case .cinemaNegative:
                String(
                    localized: "film_stock.color_negative_cinema",
                    defaultValue: "Color negative · Cinema")
            case .reversal:
                String(localized: "film_stock.color_reversal", defaultValue: "Color reversal")
            case .photoPaper:
                String(
                    localized: "film_stock.photographic_paper", defaultValue: "Photographic paper")
            case .cinemaPrint:
                String(localized: "film_stock.cinema_print_film", defaultValue: "Cinema print film")
            }
        }
        static let films: [Self] = [.photoNegative, .cinemaNegative, .reversal]
        static let prints: [Self] = [.photoPaper, .cinemaPrint]
    }
    var category: Category {
        if stage == "printing" { return support == "paper" ? .photoPaper : .cinemaPrint }
        if isPositive { return .reversal }
        // Negative groups follow the upstream stock’s intended print medium.
        if let targetPrint, Self.all.first(where: { $0.id == targetPrint })?.support == "film" {
            return .cinemaNegative
        }
        return .photoNegative
    }

}
