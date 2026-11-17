import Foundation
import Observation

nonisolated struct InstalledLUT: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    let size: Int
    let importedAt: Date
}

@MainActor @Observable final class LUTLibrary {
    private(set) var items: [InstalledLUT] = []
    let directory: URL
    private let store: LUTFiles
    private var removalHandlers: [UUID: (Set<String>) -> Void] = [:]
    func registerRemoval(_ owner: UUID, handler: @escaping (Set<String>) -> Void) {
        removalHandlers[owner] = handler
    }
    func clearReferences(to ids: Set<String>) {
        for handler in Array(removalHandlers.values) { handler(ids) }
    }
    private var references: [UUID: Set<String>] = [:]
    func protect(_ owner: UUID, ids: Set<String>) { references[owner] = ids }
    func release(_ owner: UUID) {
        references.removeValue(forKey: owner)
        removalHandlers.removeValue(forKey: owner)
    }
    init(root: URL) {
        directory = root.appendingPathComponent("LUTs", isDirectory: true)
        store = LUTFiles(directory: directory)
    }
    func load() async throws { items = try await store.load() }
    @discardableResult func importFile(_ url: URL) async throws -> InstalledLUT {
        let result = try await store.importFile(url)
        try await load()
        return result
    }
    func remove(_ ids: Set<String>, protected: Set<String>) async throws {
        let used = references.values.reduce(into: protected) { $0.formUnion($1) }
        guard ids.isDisjoint(with: used) else { throw LUTFiles.Failure.used }
        try await store.remove(ids)
        try await load()
    }
    func rename(_ id: String, name: String) async throws {
        try await store.rename(id, name: name)
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
    func name(_ id: String?) -> String? { items.first { $0.id == id }?.name }
}

actor LUTFiles {
    enum Failure: LocalizedError {
        case used
        var errorDescription: String? {
            String(
                localized: "lut.error.in_use",
                defaultValue:
                    "Keep LUTs that are used by saved edits or Undo. Remove those edits before you delete the LUTs."
            )
        }
    }
    nonisolated let directory: URL
    private var index: URL { directory.appendingPathComponent("Library.json") }
    private struct Index: Codable {
        var version = 1
        var items: [InstalledLUT]
    }
    init(directory: URL) { self.directory = directory }
    func load() throws -> [InstalledLUT] {
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        let saved = try JSONDecoder().decode(Index.self, from: Data(contentsOf: index))
        guard saved.version == 1, saved.items.allSatisfy({ CubeLUT.validID($0.id) }),
            Set(saved.items.map(\.id)).count == saved.items.count
        else {
            throw CubeLUT.Failure.format(
                String(
                    localized: "lut.error.index_unsupported",
                    defaultValue: "The LUT library index is not supported."))
        }
        return saved.items
    }
    func importFile(_ url: URL) throws -> InstalledLUT {
        guard url.pathExtension.lowercased() == "cube" else { throw CubeLUT.Failure.size }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard count <= 16 * 1024 * 1024 else { throw CubeLUT.Failure.size }
        let data = try Data(contentsOf: url)
        let cube = try CubeLUT(data: data, filename: url.lastPathComponent)
        var items = try load()
        if let index = items.firstIndex(where: { $0.id == cube.id }) {
            if items[index].name == cube.title
                && cube.title.localizedCaseInsensitiveContains("generated")
            {
                items[index].name = url.deletingPathExtension().lastPathComponent
                try save(items)
            }
            return items[index]
        }
        let item = InstalledLUT(
            id: cube.id, name: url.deletingPathExtension().lastPathComponent, size: cube.size,
            importedAt: Date())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(cube.id).appendingPathExtension("cube")
        let existed = FileManager.default.fileExists(atPath: target.path)
        if !existed { try data.write(to: target, options: .atomic) }
        items.append(item)
        do { try save(items) } catch {
            if !existed { try? FileManager.default.removeItem(at: target) }
            throw error
        }
        return item
    }
    func remove(_ ids: Set<String>) throws {
        guard ids.allSatisfy(CubeLUT.validID) else { throw CubeLUT.Failure.missing }
        try save(load().filter { !ids.contains($0.id) })
        for id in ids {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(id).appendingPathExtension("cube"))
        }
    }
    func rename(_ id: String, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else {
            throw CubeLUT.Failure.format(
                String(
                    localized: "lut.error.name_length",
                    defaultValue: "Use a name with 1 to 200 characters."))
        }
        var items = try load()
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw CubeLUT.Failure.missing
        }
        items[index].name = name
        try save(items)
    }
    func reorder(_ ids: [String]) throws {
        let items = try load()
        guard ids.count == items.count, Set(ids) == Set(items.map(\.id)) else {
            throw CubeLUT.Failure.format(
                String(
                    localized: "lut.error.list_changed",
                    defaultValue: "The LUT list changed. Try again."))
        }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        try save(ids.compactMap { byID[$0] })
    }
    private func save(_ items: [InstalledLUT]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Index(items: items)).write(to: index, options: .atomic)
    }
}
