import Foundation

/// Stable upstream parameter paths keep UI names separate from the physical model.
nonisolated struct EditRecipe: Codable, Equatable, Sendable {
    static let currentVersion = 5
    struct Source: Codable, Equatable, Sendable {
        var exposureEV = 0.0
        var warmth = 0.0
        var tint = 0.0
        var saturation = 1.0
    }
    /// RAW controls precede Develop. Whole-photo monochrome is applied at the output.
    struct Tone: Codable, Equatable, Sendable {
        var algorithm = 5
        var exposureEV = 0.0
        var contrast = 1.0
        var pivot = 0.35
        var shadows = 0.0
        var highlights = 0.0
        var monochrome = false
        var rawStage: Self {
            var copy = self
            copy.monochrome = false
            return copy
        }
        var outputStage: Self {
            var copy = Self()
            copy.monochrome = monochrome
            return copy
        }
        var isIdentity: Bool {
            exposureEV == 0 && contrast == 1 && shadows == 0 && highlights == 0 && !monochrome
        }
        init() {}
        enum CodingKeys: String, CodingKey {
            case algorithm, exposureEV, contrast, pivot, shadows, highlights, monochrome
        }
        init(from decoder: Decoder) throws {
            let v = try decoder.container(keyedBy: CodingKeys.self)
            algorithm = try v.decodeIfPresent(Int.self, forKey: .algorithm) ?? 1
            exposureEV = try v.decodeIfPresent(Double.self, forKey: .exposureEV) ?? 0
            contrast = try v.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
            pivot = try v.decodeIfPresent(Double.self, forKey: .pivot) ?? 0.35
            shadows = try v.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
            highlights = try v.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
            monochrome = try v.decodeIfPresent(Bool.self, forKey: .monochrome) ?? false
            guard (1...5).contains(algorithm) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .algorithm, in: v, debugDescription: "Unsupported tone algorithm")
            }
        }
    }
    enum LookMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case spektrafilm, lut
        var id: Self { self }
        var title: String { self == .spektrafilm ? "Spektrafilm" : "3D LUT" }
    }
    struct LUTSlot: Codable, Equatable, Sendable {
        var id: String? = nil
        var mix = 1.0
    }
    struct Look: Codable, Equatable, Sendable {
        // Model callers and legacy saved recipes retain their existing enabled look.
        // A new editor session explicitly starts with this disabled.
        var enabled = true
        var mode = LookMode.spektrafilm
        var first = LUTSlot()
        var second = LUTSlot(mix: 0)
        var identifiers: Set<String> { Set([first.id, second.id].compactMap { $0 }) }
        init() {}
        enum CodingKeys: String, CodingKey { case enabled, mode, first, second }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            mode = try values.decodeIfPresent(LookMode.self, forKey: .mode) ?? .spektrafilm
            first = try values.decodeIfPresent(LUTSlot.self, forKey: .first) ?? LUTSlot()
            second = try values.decodeIfPresent(LUTSlot.self, forKey: .second) ?? LUTSlot(mix: 0)
        }
    }
    var look = Look()
    var tone = Tone()
    var monochromeGrain = false
    var source = Source()
    var mix = 1.0
    var version = Self.currentVersion
    var upstreamRevision = "3bb2c2d2801ff68b92019cf1dbcbb133d60832bc"
    var filmID = "kodak_portra_400"
    var printID = "kodak_portra_endura"
    var scanFilm = false
    var crop = CropSelection()
    var geometry = ImageGeometry()
    var printLayout: PrintLayout?
    var filmEdgeSelection: FilmEdgeSelection?
    var filmEdgeLayout: FilmEdgeLayout?
    var temperature: Double?
    var numbers: [String: Double] = [:]
    var flags: [String: Bool] = [:]
    var choices: [String: String] = [:]

    init() {}
    enum CodingKeys: String, CodingKey {
        case source, tone, look, monochromeGrain, mix, version, upstreamRevision, filmID, printID,
            scanFilm,
            crop,
            geometry, printLayout, filmEdgeSelection, filmEdgeLayout, temperature,
            numbers,
            flags, choices
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        look = try values.decodeIfPresent(Look.self, forKey: .look) ?? Look()
        tone = try values.decodeIfPresent(Tone.self, forKey: .tone) ?? Tone()
        monochromeGrain = try values.decodeIfPresent(Bool.self, forKey: .monochromeGrain) ?? false
        source = try values.decodeIfPresent(Source.self, forKey: .source) ?? Source()
        mix = try values.decodeIfPresent(Double.self, forKey: .mix) ?? 1
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...Self.currentVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: values, debugDescription: "Unsupported edit-recipe version")
        }
        version = Self.currentVersion  // Tone keeps its own algorithm for older grades.
        upstreamRevision =
            try values.decodeIfPresent(String.self, forKey: .upstreamRevision) ?? upstreamRevision
        filmID = try values.decodeIfPresent(String.self, forKey: .filmID) ?? filmID
        printID = try values.decodeIfPresent(String.self, forKey: .printID) ?? printID
        scanFilm = try values.decodeIfPresent(Bool.self, forKey: .scanFilm) ?? false
        crop = try values.decodeIfPresent(CropSelection.self, forKey: .crop) ?? CropSelection()
        geometry =
            try values.decodeIfPresent(ImageGeometry.self, forKey: .geometry) ?? ImageGeometry()
        printLayout = try values.decodeIfPresent(PrintLayout.self, forKey: .printLayout)
        filmEdgeSelection = try values.decodeIfPresent(FilmEdgeSelection.self, forKey: .filmEdgeSelection)
        filmEdgeLayout = try values.decodeIfPresent(FilmEdgeLayout.self, forKey: .filmEdgeLayout)
        temperature = try values.decodeIfPresent(Double.self, forKey: .temperature)
        numbers = try values.decodeIfPresent([String: Double].self, forKey: .numbers) ?? [:]
        flags = try values.decodeIfPresent([String: Bool].self, forKey: .flags) ?? [:]
        choices = try values.decodeIfPresent([String: String].self, forKey: .choices) ?? [:]
    }

    func number(_ path: String) -> Double {
        numbers[path] ?? defaultNumber(path)
    }
    func defaultNumber(_ path: String) -> Double {
        StockDefaults.numbers[look.mode == .lut ? "kodak_portra_400" : filmID]?[path]
            ?? ParameterDefinition.byPath[path]?.defaultNumber ?? 0
    }
    func flag(_ path: String) -> Bool {
        flags[path] ?? ParameterDefinition.byPath[path]?.defaultFlag ?? false
    }
    func choice(_ path: String) -> String {
        choices[path] ?? ParameterDefinition.byPath[path]?.defaultChoice ?? ""
    }
    mutating func removeDefaultOverrides() {
        numbers = numbers.filter { defaultNumber($0.key) != $0.value }
        flags = flags.filter { ParameterDefinition.byPath[$0.key]?.defaultFlag != $0.value }
        choices = choices.filter { ParameterDefinition.byPath[$0.key]?.defaultChoice != $0.value }
    }
    /// A new stock uses its natural route; a print choice is retained for later printing.
    mutating func selectFilm(_ stock: FilmStock) {
        guard stock.id != filmID else { return }
        let resetKeys = Set(StockDefaults.numbers[filmID]?.keys.map { $0 } ?? []).union(
            stock.defaults.keys)
        filmID = stock.id
        for key in resetKeys { numbers.removeValue(forKey: key) }
        scanFilm = stock.isPositive
    }
    /// UI stops map to the upstream linear enlarger exposure multiplier.
    var printExposureEV: Double {
        get { log2(max(number("enlarger.print_exposure"), pow(2, -10))) }
        set { numbers["enlarger.print_exposure"] = pow(2, newValue) }
    }
    /// Geometry is applied after film rendering and must not invalidate its expensive cache.
    var processingRecipe: Self {
        var copy = self
        copy.crop = CropSelection()
        copy.geometry = ImageGeometry()
        copy.printLayout = nil
        copy.filmEdgeSelection = nil
        copy.filmEdgeLayout = nil
        return copy
    }
    var inputMode: LookMode { look.enabled ? look.mode : .lut }
    func removingLUTs(_ ids: Set<String>) -> Self {
        var copy = self
        if let id = copy.look.first.id, ids.contains(id) { copy.look.first.id = nil }
        if let id = copy.look.second.id, ids.contains(id) { copy.look.second.id = nil }
        return copy
    }
    var bypassesPrint: Bool { look.mode == .spektrafilm && scanFilm }
    var resolvedFilmEdgeType: FilmEdgeType {
        (filmEdgeSelection ?? FilmEdgeSelection()).resolvedType(for: self)
    }
}

nonisolated struct ParameterDefinition: Identifiable, Sendable {
    let id: String
    let title: String
    var defaultNumber: Double?
    var defaultFlag: Bool?
    var defaultChoice: String?
    var options: [String] = []
    var sliderRange: ClosedRange<Double> = 0...1
    var step: Double = 0.01
    var minimum: Double?
    var maximum: Double?
    var unit: String = ""

    static func number(
        _ id: String, _ title: String, _ value: Double, _ range: ClosedRange<Double>,
        step: Double, minimum: Double?, maximum: Double?, unit: String
    ) -> Self {
        .init(
            id: id, title: title, defaultNumber: value, sliderRange: range,
            step: step, minimum: minimum, maximum: maximum, unit: unit)
    }
    static func flag(_ id: String, _ title: String, _ value: Bool) -> Self {
        .init(id: id, title: title, defaultFlag: value)
    }
    static func choice(_ id: String, _ title: String, _ value: String, _ options: [String]) -> Self
    {
        .init(id: id, title: title, defaultChoice: value, options: options)
    }
    static let byGroup = Dictionary(grouping: catalog) { definition in
        definition.id.split(separator: ".").dropLast().joined(separator: ".")
    }
    var fieldName: String { String(id.split(separator: ".").last!.split(separator: "[").first!) }
    static let byPath = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
}
