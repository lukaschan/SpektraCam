import CryptoKit
import Foundation

/// A named, reusable look: one recipe without its framing, and the parts of it that apply.
/// The file on disk is the file that is shared, so reading is tolerant and nothing a newer
/// SpektraCam wrote is thrown away.
nonisolated struct Formula: Identifiable, Equatable, Sendable {
    static let fileExtension = "rnformula"
    static let format = 1
    /// The newest version of each part this build reads. Raise one only when stored values
    /// change meaning; a field that is merely added decodes with its default and needs no bump.
    /// A Darkroom upgrade raises only Darkroom, and older builds still apply the Look.
    static let readable: [EditRecipe.Part: Int] = [.look: 1, .exposure: 1, .darkroom: 1]

    /// Enough to ask for the right file: a LUT's id is the SHA-256 of its bytes.
    struct LUT: Codable, Equatable, Identifiable, Sendable {
        let id: String
        var name: String
        var size: Int
    }
    enum Failure: LocalizedError {
        case unreadable, newer, name
        var errorDescription: String? {
            switch self {
            case .unreadable:
                String(localized: "formula.error.unreadable", defaultValue: "This is not a formula file.")
            case .newer:
                String(
                    localized: "formula.error.newer",
                    defaultValue: "This formula needs a newer version of SpektraCam.")
            case .name:
                String(localized: "formula.error.name", defaultValue: "Use a name with 1 to 80 characters.")
            }
        }
    }

    let id: UUID
    var name: String
    var note: String
    var created: Date
    /// Parts this build can apply, in process order.
    var parts: [EditRecipe.Part]
    /// Parts in the file that need a newer SpektraCam. They stay in the file as written.
    var unreadable: [String]
    var recipe: EditRecipe
    var luts: [LUT]

    /// A new formula from an edit. Only the chosen parts are kept, so a part the author left
    /// out is not carried along in the file.
    init(name: String, note: String = "", parts: Set<EditRecipe.Part>, from source: EditRecipe, luts: [LUT]) throws {
        id = UUID()
        self.name = try Self.validated(name)
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        created = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))  // As stored.
        let clip = LookClip(source)
        self.parts = clip.parts.filter(parts.contains)
        unreadable = []
        let kept = EditRecipe().taking(Set(self.parts), from: clip.recipe, rawTarget: true)
        recipe = kept
        self.luts = self.parts.contains(.look) ? luts.filter { kept.look.identifiers.contains($0.id) } : []
    }
    static func validated(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw Failure.name }
        return name
    }
    /// LUTs the formula calls for that are not installed.
    func missingLUTs(installed: Set<String>) -> [LUT] {
        guard parts.contains(.look) else { return [] }
        let needed = recipe.look.identifiers.subtracting(installed)
        return needed.sorted().map { id in luts.first { $0.id == id } ?? LUT(id: id, name: "", size: 0) }
    }

    // MARK: File

    private static let darkroomKeys = ["printLayout", "filmEdgeSelection", "filmEdgeLayout"]
    private struct File: Encodable {
        let format: Int, id: UUID, name: String, note: String, created: Date
        let parts: [String: Int]
        let recipe: EditRecipe
        let luts: [LUT]
    }
    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        var versions: [String: Int] = [:]
        for part in parts { versions[part.rawValue] = Self.readable[part] }
        return try encoder.encode(
            File(
                format: Self.format, id: id, name: name, note: note, created: created,
                parts: versions, recipe: recipe, luts: luts))
    }
    /// Read a formula file. Parts written by a newer SpektraCam are listed in `unreadable`
    /// and left out of `parts`; the rest still applies.
    init(data: Data, limit: Int = storedLimit) throws {
        guard data.count <= limit,
            let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let format = (file["format"] as? NSNumber)?.intValue,
            let id = (file["id"] as? String).flatMap(UUID.init(uuidString:)),
            let name = file["name"] as? String,
            let versions = file["parts"] as? [String: Any],
            var stored = file["recipe"] as? [String: Any]
        else { throw Failure.unreadable }
        guard format <= Self.format else { throw Failure.newer }
        self.id = id
        self.name = try Self.validated(name)
        note = (file["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        created =
            (file["created"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            ?? Date(timeIntervalSince1970: 0)
        var readable: [EditRecipe.Part] = []
        var newer: [String] = []
        for (key, value) in versions {
            if let part = EditRecipe.Part(rawValue: key), let version = (value as? NSNumber)?.intValue,
                version >= 1, version <= Self.readable[part] ?? 0
            {
                readable.append(part)
            } else {
                newer.append(key)
            }
        }
        func decode(_ recipe: [String: Any]) -> EditRecipe? {
            (try? JSONSerialization.data(withJSONObject: recipe)).flatMap {
                try? JSONDecoder().decode(EditRecipe.self, from: $0)
            }
        }
        if !readable.contains(.darkroom) { for key in Self.darkroomKeys { stored[key] = nil } }
        var decoded = decode(stored)
        if decoded == nil, readable.contains(.darkroom) {
            // An added paper or gate is a value this build cannot name. The Look still reads.
            for key in Self.darkroomKeys { stored[key] = nil }
            decoded = decode(stored)
            if decoded != nil {
                readable.removeAll { $0 == .darkroom }
                newer.append(EditRecipe.Part.darkroom.rawValue)
            }
        }
        if let decoded, decoded.upstreamRevision == EditRecipe().upstreamRevision {
            recipe = LookClip(decoded.sanitized()).recipe
        } else {
            recipe = EditRecipe()
            newer += readable.map(\.rawValue)
            readable = []
        }
        parts = EditRecipe.Part.allCases.filter(readable.contains)
        unreadable = newer.sorted()
        luts =
            (file["luts"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let id = entry["id"] as? String, EditRecipe.validLUT(id) else { return nil }
                return LUT(
                    id: id, name: String((entry["name"] as? String ?? "").prefix(200)),
                    size: (entry["size"] as? NSNumber)?.intValue ?? 0)
            }
    }
    /// A stored formula is small. A shared one may carry its LUT files.
    static let storedLimit = 1024 * 1024
    static let sharedLimit = 40 * 1024 * 1024

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadable
        }
        return file
    }
    private static func encoded(_ file: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: file, options: [.sortedKeys, .prettyPrinted])
    }
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    /// LUT files carried inside a shared formula, each a `.cube` text. One whose bytes do not
    /// hash to its id is not what the formula asked for and is dropped.
    static func attachments(in data: Data) -> [(id: String, name: String, cube: Data)] {
        guard let file = try? object(data), let entries = file["attachments"] as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, let text = entry["cube"] as? String else { return nil }
            let cube = Data(text.utf8)
            guard EditRecipe.validLUT(id), hash(cube) == id else { return nil }
            return (id, String((entry["name"] as? String ?? "").prefix(200)), cube)
        }
    }
    /// The same file carrying these LUT files, for sharing with someone who lacks them.
    static func attaching(_ data: Data, luts: [(name: String, cube: Data)]) throws -> Data {
        var file = try object(data)
        let entries: [[String: Any]] = luts.compactMap { lut in
            guard let text = String(data: lut.cube, encoding: .utf8), Data(text.utf8) == lut.cube else {
                return nil
            }
            return ["id": hash(lut.cube), "name": lut.name, "cube": text]
        }
        file["attachments"] = entries.isEmpty ? nil : entries
        return try encoded(file)
    }
    /// The file as it is kept: LUT files live in the LUT library, not in each formula.
    static func strippingAttachments(_ data: Data) throws -> Data {
        var file = try object(data)
        guard file["attachments"] != nil else { return data }
        file["attachments"] = nil
        return try encoded(file)
    }
    /// Point a formula at another LUT. This is the one edit that changes its look, and only
    /// the user makes it.
    static func replacingLUT(_ data: Data, _ old: String, with new: LUT) throws -> Data {
        var file = try object(data)
        guard var recipe = file["recipe"] as? [String: Any], var look = recipe["look"] as? [String: Any]
        else { throw Failure.unreadable }
        for slot in ["first", "second"] {
            guard var value = look[slot] as? [String: Any], value["id"] as? String == old else { continue }
            value["id"] = new.id
            look[slot] = value
        }
        recipe["look"] = look
        file["recipe"] = recipe
        var references = (file["luts"] as? [[String: Any]] ?? []).filter {
            let id = $0["id"] as? String
            return id != old && id != new.id
        }
        references.append(["id": new.id, "name": new.name, "size": new.size])
        file["luts"] = references
        return try encoded(file)
    }
    /// Change the name and note in a stored file without re-encoding the rest, so fields this
    /// build does not know survive the edit.
    static func renaming(_ data: Data, name: String, note: String) throws -> Data {
        guard var file = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadable
        }
        file["name"] = try validated(name)
        file["note"] = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return try JSONSerialization.data(withJSONObject: file, options: [.sortedKeys, .prettyPrinted])
    }
    /// The same formula under a new identity, for Duplicate and for importing a copy.
    static func duplicating(_ data: Data, name: String) throws -> (id: UUID, data: Data) {
        guard var file = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadable
        }
        let id = UUID()
        file["id"] = id.uuidString
        file["name"] = try validated(name)
        return (id, try JSONSerialization.data(withJSONObject: file, options: [.sortedKeys, .prettyPrinted]))
    }
}

nonisolated extension EditRecipe {
    static func validLUT(_ id: String) -> Bool {
        id.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    /// A recipe from outside the app: keep what this build knows, within each control's limits.
    func sanitized() -> EditRecipe {
        var copy = self
        copy.numbers = numbers.reduce(into: [:]) { result, entry in
            guard let field = ParameterDefinition.byPath[entry.key], field.defaultNumber != nil,
                entry.value.isFinite
            else { return }
            let low = field.minimum ?? -Double.greatestFiniteMagnitude
            let high = field.maximum ?? Double.greatestFiniteMagnitude
            result[entry.key] = min(max(entry.value, low), high)
        }
        copy.flags = flags.filter { ParameterDefinition.byPath[$0.key]?.defaultFlag != nil }
        copy.choices = choices.filter { ParameterDefinition.byPath[$0.key]?.options.contains($0.value) == true }
        func finite(_ value: Double, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        copy.mix = finite(mix, 1, 0...1)
        copy.look.first.mix = finite(look.first.mix, 1, 0...1)
        copy.look.second.mix = finite(look.second.mix, 0, 0...1)
        if let id = look.first.id, !Self.validLUT(id) { copy.look.first.id = nil }
        if let id = look.second.id, !Self.validLUT(id) { copy.look.second.id = nil }
        copy.tone.exposureEV = finite(tone.exposureEV, 0, -10...10)
        copy.tone.contrast = finite(tone.contrast, 1, 0.65...1.35)
        copy.tone.pivot = finite(tone.pivot, 0.35, 0...1)
        copy.tone.shadows = finite(tone.shadows, 0, -5...5)
        copy.tone.highlights = finite(tone.highlights, 0, -5...5)
        copy.source.exposureEV = finite(source.exposureEV, 0, -10...10)
        copy.source.warmth = finite(source.warmth, 0, -100...100)
        copy.source.tint = finite(source.tint, 0, -100...100)
        copy.source.saturation = finite(source.saturation, 1, 0...2)
        if let kelvin = temperature, !kelvin.isFinite || kelvin < 1000 || kelvin > 50000 { copy.temperature = nil }
        copy.removeDefaultOverrides()
        return copy
    }
}
