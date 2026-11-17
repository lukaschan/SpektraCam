import CoreTransferable
import Foundation
import Observation
import UniformTypeIdentifiers

/// Saved formulae in the user's order. Each is one file, the same file that is shared.
@MainActor @Observable final class FormulaLibrary {
    private(set) var items: [Formula] = []
    private(set) var favorites: Set<UUID> = []
    let directory: URL
    private let store: FormulaFiles

    init(root: URL) {
        directory = root.appendingPathComponent("Formulae", isDirectory: true)
        store = FormulaFiles(directory: directory)
    }
    /// Favourites lead; otherwise the order of the manager's list.
    var ordered: [Formula] {
        items.filter { favorites.contains($0.id) } + items.filter { !favorites.contains($0.id) }
    }
    /// LUTs a formula calls for. A plain LUT delete keeps them.
    var lutIdentifiers: Set<String> {
        items.reduce(into: Set<String>()) { result, formula in
            if formula.parts.contains(.look) { result.formUnion(formula.recipe.look.identifiers) }
        }
    }
    func formula(_ id: UUID) -> Formula? { items.first { $0.id == id } }
    /// The stored file, which is also the file that is shared.
    nonisolated func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(Formula.fileExtension)
    }
    enum Conflict { case replace, keepBoth }
    /// Whether a formula file is new here, already here unchanged, or a different version of
    /// one that is here.
    enum Arrival: Equatable { case new, same, changed }
    func arrival(of data: Data) async -> Arrival {
        guard let formula = try? Formula(data: data, limit: Formula.sharedLimit), self.formula(formula.id) != nil,
            let kept = try? Formula.strippingAttachments(data)
        else { return .new }
        return await store.matches(formula.id, kept) ? .same : .changed
    }
    /// Add a formula file from outside. LUT files it carries are not stored with it; install
    /// them in the LUT library first.
    @discardableResult func add(_ data: Data, conflict: Conflict = .replace) async throws -> UUID {
        let id = try await store.add(data, keepBoth: conflict == .keepBoth)
        try await load()
        return id
    }
    func replaceLUT(in id: UUID, _ old: String, with new: Formula.LUT) async throws {
        try await store.replaceLUT(in: id, old, with: new)
        try await load()
    }

    func load() async throws {
        let saved = try await store.load()
        items = saved.items
        favorites = saved.favorites
    }
    @discardableResult func save(_ formula: Formula) async throws -> Formula {
        try await store.save(formula)
        try await load()
        return formula
    }
    func rename(_ id: UUID, name: String, note: String) async throws {
        try await store.rename(id, name: name, note: note)
        try await load()
    }
    @discardableResult func duplicate(_ id: UUID, name: String) async throws -> UUID {
        let copy = try await store.duplicate(id, name: name)
        try await load()
        return copy
    }
    func remove(_ ids: Set<UUID>) async throws {
        try await store.remove(ids)
        try await load()
    }
    func setFavorite(_ id: UUID, _ favorite: Bool) async throws {
        try await store.setFavorite(id, favorite)
        try await load()
    }
    func move(from offsets: IndexSet, to destination: Int) async throws {
        var ordered = items
        let moved = offsets.sorted().map { ordered[$0] }
        let target = destination - offsets.filter { $0 < destination }.count
        for index in offsets.sorted(by: >) { ordered.remove(at: index) }
        ordered.insert(contentsOf: moved, at: target)
        try await store.reorder(ordered.map(\.id))
        try await load()
    }
}

actor FormulaFiles {
    nonisolated let directory: URL
    private var index: URL { directory.appendingPathComponent("Library.json") }
    private struct Index: Codable {
        var version = 1
        var order: [UUID] = []
        var favorites: [UUID] = []
    }
    init(directory: URL) { self.directory = directory }

    private func url(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(Formula.fileExtension)
    }
    private func readIndex() -> Index {
        (try? Data(contentsOf: index)).flatMap { try? JSONDecoder().decode(Index.self, from: $0) } ?? Index()
    }
    private func write(_ value: Index) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: index, options: .atomic)
    }
    /// The files are the truth. The index only orders them, so a lost index loses no formula,
    /// and a file this build cannot read stays on disk untouched.
    func load() throws -> (items: [Formula], favorites: Set<UUID>) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], []) }
        var found: [UUID: Formula] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == Formula.fileExtension {
            guard let data = try? Data(contentsOf: file), let formula = try? Formula(data: data),
                formula.id.uuidString == file.deletingPathExtension().lastPathComponent
            else { continue }
            found[formula.id] = formula
        }
        let saved = readIndex()
        var items = saved.order.compactMap { found.removeValue(forKey: $0) }
        items += found.values.sorted { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) }
        return (items, Set(saved.favorites).intersection(items.map(\.id)))
    }
    func save(_ formula: Formula) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try formula.data().write(to: url(formula.id), options: .atomic)
        var saved = readIndex()
        if !saved.order.contains(formula.id) { saved.order.append(formula.id) }
        try write(saved)
    }
    func rename(_ id: UUID, name: String, note: String) throws {
        let data = try Formula.renaming(Data(contentsOf: url(id)), name: name, note: note)
        try data.write(to: url(id), options: .atomic)
    }
    func duplicate(_ id: UUID, name: String) throws -> UUID {
        let copy = try Formula.duplicating(Data(contentsOf: url(id)), name: name)
        try copy.data.write(to: url(copy.id), options: .atomic)
        var saved = readIndex()
        let position = saved.order.firstIndex(of: id).map { $0 + 1 } ?? saved.order.count
        saved.order.insert(copy.id, at: position)
        try write(saved)
        return copy.id
    }
    func remove(_ ids: Set<UUID>) throws {
        var saved = readIndex()
        saved.order.removeAll(where: ids.contains)
        saved.favorites.removeAll(where: ids.contains)
        try write(saved)
        for id in ids { try? FileManager.default.removeItem(at: url(id)) }
    }
    func matches(_ id: UUID, _ data: Data) -> Bool {
        // A link leaves out the framing a formula never has; the file it came from is still the same.
        func settings(_ data: Data) -> NSDictionary? {
            guard var file = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if var recipe = file["recipe"] as? [String: Any] {
                for key in FormulaLink.framing { recipe[key] = nil }
                file["recipe"] = recipe
            }
            return file as NSDictionary
        }
        guard let stored = try? Data(contentsOf: url(id)), let a = settings(stored), let b = settings(data)
        else { return false }
        return a == b
    }
    func add(_ incoming: Data, keepBoth: Bool) throws -> UUID {
        var data = try Formula.strippingAttachments(incoming)
        var formula = try Formula(data: data)
        if keepBoth, FileManager.default.fileExists(atPath: url(formula.id).path) {
            let copy = try Formula.duplicating(data, name: formula.name)
            data = copy.data
            formula = try Formula(data: data)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(formula.id), options: .atomic)
        var saved = readIndex()
        if !saved.order.contains(formula.id) { saved.order.append(formula.id) }
        try write(saved)
        return formula.id
    }
    func replaceLUT(in id: UUID, _ old: String, with new: Formula.LUT) throws {
        let data = try Formula.replacingLUT(Data(contentsOf: url(id)), old, with: new)
        _ = try Formula(data: data)
        try data.write(to: url(id), options: .atomic)
    }
    func setFavorite(_ id: UUID, _ favorite: Bool) throws {
        var saved = readIndex()
        saved.favorites.removeAll { $0 == id }
        if favorite { saved.favorites.append(id) }
        try write(saved)
    }
    func reorder(_ ids: [UUID]) throws {
        var saved = readIndex()
        saved.order = ids
        try write(saved)
    }
}

extension UTType {
    /// Declared in Configuration/SpektraCam-Info.plist, with the `.rnformula` extension.
    nonisolated static let spektraFormula = UTType(exportedAs: "io.github.runzeni.spektracam.formula")
}

/// A formula as a file for the share sheet. The stored file is sent as it is; LUT files are
/// added only when the sharer chose to carry them.
nonisolated struct FormulaFile: Transferable, Sendable {
    struct Carried: Sendable {
        let name: String
        let url: URL
    }
    let name: String
    let source: URL
    var luts: [Carried] = []

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .spektraFormula) { file in
            SentTransferredFile(try file.export())
        }
    }
    /// A copy named after the formula, in a folder of its own so the name is never altered.
    func export() throws -> URL {
        var data = try Data(contentsOf: source)
        if !luts.isEmpty {
            data = try Formula.attaching(
                data, luts: luts.compactMap { lut in (try? Data(contentsOf: lut.url)).map { (lut.name, $0) } })
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Formula-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = name.map { "/:\\".contains($0) ? "-" : $0 }
        let url = folder.appendingPathComponent(String(safe)).appendingPathExtension(Formula.fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }
}

extension FormulaLibrary {
    /// The file to share. With `carryingLUTs`, the installed LUT files the look uses go inside it.
    func file(_ formula: Formula, carryingLUTs luts: LUTLibrary? = nil) -> FormulaFile {
        var carried: [FormulaFile.Carried] = []
        if let luts, formula.parts.contains(.look) {
            carried = luts.items.filter { formula.recipe.look.identifiers.contains($0.id) }.map {
                .init(name: $0.name, url: luts.directory.appendingPathComponent($0.id).appendingPathExtension("cube"))
            }
        }
        return FormulaFile(name: formula.name, source: fileURL(formula.id), luts: carried)
    }
}
