import Foundation
import Observation

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
