import CoreGraphics
import Foundation
import Observation
import SwiftData

/// The database owns the index and recipe. Original files never change after import.
@MainActor @Observable final class PhotoLibrary {
    private(set) var photos: [LibraryPhoto] = []
    var saveFailure: String?
    let files: LibraryFiles
    let images: LibraryImages
    let luts: LUTLibrary
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var records: [UUID: LibrarySchemaV1.Record] = [:]
    private(set) var importedAssetIdentifiers: [String] = []
    @ObservationIgnored private var sources: [String: LibrarySchemaV2.PhotosSource] = [:]
    @ObservationIgnored private var pending: [UUID: EditRecipe] = [:]
    @ObservationIgnored private var saves: [UUID: Task<Void, Never>] = [:]

    init(root: URL? = nil, cache: URL? = nil, modelDirectory: URL? = nil) throws {
        let root =
            try root
            ?? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("SpektraCam")
        let cache =
            try cache
            ?? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("SpektraCam")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: LibrarySchemaV2.self)
        let configuration = ModelConfiguration(
            "Library", schema: schema,
            url: root.appendingPathComponent("Library.store"), cloudKitDatabase: .none)
        container = try ModelContainer(
            for: schema, migrationPlan: LibraryMigrationPlan.self, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
        for record in try context.fetch(FetchDescriptor<LibrarySchemaV1.Record>()) {
            records[record.id] = record
        }
        let initial = try records.values.map { try $0.snapshot() }.sorted(by: Self.order)
        files = try LibraryFiles(root: root, cache: cache, validIDs: Set(initial.map(\.id)))
        images = LibraryImages(files: files, directory: modelDirectory ?? Bundle.main.resourceURL!)
        luts = LUTLibrary(root: root)
        photos = initial
        for source in try context.fetch(FetchDescriptor<LibrarySchemaV2.PhotosSource>()) {
            sources[source.assetIdentifier] = source
        }
        importedAssetIdentifiers = sources.keys.sorted()
    }
    private static func order(_ a: LibraryPhoto, _ b: LibraryPhoto) -> Bool {
        a.date == b.date
            ? (a.importedAt == b.importedAt
                ? a.id.uuidString < b.id.uuidString : a.importedAt < b.importedAt)
            : a.date < b.date
    }
    func photo(_ id: UUID) -> LibraryPhoto? { photos.first { $0.id == id } }
    @discardableResult func importPhoto(
        _ url: URL, now: Date = Date(), assetIdentifier: String? = nil
    )
        async throws -> LibraryPhoto
    {
        if let assetIdentifier, let id = sources[assetIdentifier]?.photoID, let existing = photo(id)
        {
            return existing
        }
        let imported = try await files.importPhoto(from: url, now: now)
        if let existing = records.values.first(where: { $0.contentHash == imported.contentHash }) {
            try await files.removeFiles(imported)
            try rememberSource(assetIdentifier, photoID: existing.id)
            return try existing.snapshot()
        }
        do {
            let record = try LibrarySchemaV1.Record(imported)
            context.insert(record)
            try rememberSource(assetIdentifier, photoID: imported.id)  // Saves the record and identifier together.
            records[imported.id] = record
            photos.append(imported)
            photos.sort(by: Self.order)
        } catch {
            context.rollback()
            try? await files.removeFiles(imported)
            throw error
        }
        return imported
    }
    private func rememberSource(_ identifier: String?, photoID: UUID) throws {
        let source = identifier.map {
            LibrarySchemaV2.PhotosSource(assetIdentifier: $0, photoID: photoID)
        }
        if let source { context.insert(source) }
        do { try context.save() } catch {
            context.rollback()
            throw error
        }
        if let source {
            sources[source.assetIdentifier] = source
            importedAssetIdentifiers = sources.keys.sorted()
        }
    }

    /// Remove an inbox file only after its original and database record are durable.
    @discardableResult func recoverCaptures() async throws -> Int {
        var count = 0
        var failure: Error?
        for url in try await files.pendingCaptures() {
            do {
                _ = try await importPhoto(url)
                try await files.removeCapture(url)
                count += 1
            } catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
        return count
    }

    var usedLUTIdentifiers: Set<String> {
        var ids = Set<String>()
        for record in records.values {
            if let data = record.recipeData {
                guard let recipe = try? JSONDecoder().decode(EditRecipe.self, from: data) else {
                    return Set(luts.items.map(\.id))
                }
                ids.formUnion(recipe.look.identifiers)
            }
        }
        for recipe in pending.values { ids.formUnion(recipe.look.identifiers) }
        return ids
    }
    /// Repair old iOS RAW index entries without decoding pixels or changing originals/edits.
    func repairRAWDimensions() async throws {
        for photo in photos
        where photo.isRAW && max(photo.metadata.width, photo.metadata.height) <= 1080 {
            try Task.checkCancellation()
            guard let size = await files.nativeRAWSize(photo), size.width > 0, size.height > 0,
                let record = records[photo.id]
            else { continue }
            var metadata = photo.metadata
            metadata.width = Int(size.width)
            metadata.height = Int(size.height)
            guard metadata != photo.metadata else { continue }
            record.metadataData = try JSONEncoder().encode(metadata)
            try context.save()
            if let index = photos.firstIndex(where: { $0.id == photo.id }) {
                photos[index] = try record.snapshot()
            }
        }
    }
    func queueRecipe(_ recipe: EditRecipe, for id: UUID, immediate: Bool = false) {
        guard records[id] != nil else { return }
        pending[id] = recipe
        saves[id]?.cancel()
        if immediate {
            do { try flush(id) } catch { saveFailure = error.localizedDescription }
        } else {
            saves[id] = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                do { try self.flush(id) } catch { self.saveFailure = error.localizedDescription }
            }
        }
    }
    func flushPending() throws { for id in Array(pending.keys) { try flush(id) } }
    /// Publish saved editor changes when returning through Camera, without rebuilding
    /// gallery thumbnails on every slider update while the editor is still open.
    func flushForLibrary() throws {
        try flushPending()
        for index in photos.indices {
            guard let record = records[photos[index].id], record.renderKey != photos[index].renderKey else { continue }
            photos[index] = try record.snapshot()
        }
    }
    private func flush(_ id: UUID) throws {
        guard let recipe = pending[id], let record = records[id] else { return }
        try persistRecipe(recipe, record: record)
        pending[id] = nil
        saveFailure = nil
    }
    private func persistRecipe(_ recipe: EditRecipe?, record: LibrarySchemaV1.Record) throws {
        let data = try recipe.map(LibraryPhoto.recipeData)
        guard data != record.recipeData else { return }
        let previousData = record.recipeData
        let previousKey = record.renderKey
        record.recipeData = data
        record.renderKey = data.map(LibraryPhoto.key) ?? "original"
        do { try context.save() } catch {
            record.recipeData = previousData
            record.renderKey = previousKey
            throw error
        }
    }
    /// Commit reference changes before deleting files. Failure keeps original files and all other adjustments.
    func forceDeleteLUTs(_ ids: Set<String>) async throws {
        try flushPending()
        var changes: [(LibrarySchemaV1.Record, Data?, String, Data)] = []
        for record in records.values {
            guard let data = record.recipeData else { continue }
            let recipe = try JSONDecoder().decode(EditRecipe.self, from: data)
            guard !recipe.look.identifiers.isDisjoint(with: ids) else { continue }
            let updated = try LibraryPhoto.recipeData(recipe.removingLUTs(ids))
            changes.append((record, record.recipeData, record.renderKey, updated))
        }
        for (record, _, _, updated) in changes {
            record.recipeData = updated
            record.renderKey = LibraryPhoto.key(updated)
        }
        do { try context.save() } catch {
            for (record, data, key, _) in changes {
                record.recipeData = data
                record.renderKey = key
            }
            throw error
        }
        for (record, _, _, _) in changes {
            if let index = photos.firstIndex(where: { $0.id == record.id }) {
                photos[index] = try record.snapshot()
            }
        }
        luts.clearReferences(to: ids)
        await images.discardMemory()
        try await luts.remove(ids, protected: usedLUTIdentifiers)
    }
    func revert(_ ids: Set<UUID>) async throws {
        for id in ids {
            guard let record = records[id], record.recipeData != nil else { continue }
            saves[id]?.cancel()
            try persistRecipe(nil, record: record)
            pending[id] = nil
            if let index = photos.firstIndex(where: { $0.id == id }) {
                photos[index] = try record.snapshot()
            }
        }
        await images.discardMemory()
    }
    func finishEditing(_ id: UUID, recipe: EditRecipe?) async throws {
        guard let record = records[id] else { throw LibraryFiles.Failure.missing }
        saves[id]?.cancel()
        if recipe == nil && record.recipeData == nil {
            pending[id] = nil
            return
        }
        if let recipe, let data = record.recipeData,
            try JSONDecoder().decode(EditRecipe.self, from: data) == recipe
        {
            // Do not rewrite an unchanged legacy recipe just because its decoded schema
            // is newer. A pending save may already have updated only the database.
            pending[id] = nil
            if let index = photos.firstIndex(where: { $0.id == id }) {
                photos[index] = try record.snapshot()
            }
            return
        }
        if let recipe {
            pending[id] = recipe
            try flush(id)
        } else {
            pending[id] = nil
            try persistRecipe(nil, record: record)
        }
        let saved = try record.snapshot()
        // Caches are replaceable. A cache failure must not undo a durable recipe save.
        // Viewer previews have their own resolution and color policy. Rebuild from the source,
        // rather than storing an editor interaction proxy under a higher-quality cache key.
        await images.discardMemory()
        if let index = photos.firstIndex(where: { $0.id == id }) { photos[index] = saved }
    }
    func recipe(_ id: UUID) throws -> EditRecipe? {
        guard let record = records[id] else { throw LibraryFiles.Failure.missing }
        if let pending = pending[id] { return pending }
        guard let data = record.recipeData else { return nil }
        // Preserve unknown or damaged recipes. Never replace them with defaults.
        return try JSONDecoder().decode(EditRecipe.self, from: data)
    }
    func setLocationName(_ name: String, for id: UUID) throws {
        guard let record = records[id] else { return }
        record.locationName = name
        try context.save()
        if let index = photos.firstIndex(where: { $0.id == id }) {
            photos[index] = try record.snapshot()
        }
    }
    func delete(_ ids: Set<UUID>) async throws {
        for id in ids {
            guard let record = records[id], let photo = photo(id) else { continue }
            saves[id]?.cancel()
            saves[id] = nil
            pending[id] = nil
            let staged = try await files.stageRemoval(photo)
            context.delete(record)
            let links = sources.values.filter { $0.photoID == id }
            for link in links { context.delete(link) }
            do { try context.save() } catch {
                context.rollback()
                try? await files.restore(staged, photo: photo)
                throw error
            }
            for link in links { sources[link.assetIdentifier] = nil }
            importedAssetIdentifiers = sources.keys.sorted()
            records[id] = nil
            photos.removeAll { $0.id == id }
            await files.finishRemoval(staged, photo: photo)
        }
        await images.discardMemory()
    }
}
