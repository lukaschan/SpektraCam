import Foundation
import Observation

@MainActor @Observable final class BatchExportModel {
    enum Outcome {
        case saved, shared
        case ready(URL)
        case failed(String)
    }
    let items: [BatchExportItem]
    let library: PhotoLibrary
    private let worker: BatchPhotoExporter
    typealias Export =
        @Sendable (BatchExportItem, PhotoExporter.Size, PhotoExporter.Format, Double) async throws
        -> URL
    private let export: Export
    private let owner = UUID()
    var outcomes: [UUID: Outcome] = [:]
    var activeID: UUID?
    var running = false
    var cancelled = false
    var stopReason: String?
    var assessments: [UUID: String] = [:]
    private var task: Task<Void, Never>?
    private var dismissed = false
    var remainingCount: Int {
        items.filter {
            switch outcomes[$0.id] {
            case .saved?, .shared?, .ready?: return false
            default: return true
            }
        }.count
    }
    var readyURLs: [URL] {
        items.compactMap {
            if case .ready(let url) = outcomes[$0.id] { return url }
            return nil
        }
    }
    var failureCount: Int {
        outcomes.values.filter {
            if case .failed = $0 { return true }
            return false
        }.count
    }
    var completedCount: Int { outcomes.count }
    init(items: [BatchExportItem], library: PhotoLibrary, export: Export? = nil) {
        self.items = items
        self.library = library
        let worker = BatchPhotoExporter(
            directory: Bundle.main.resourceURL!,
            luts: library.luts.directory, resources: library.images.resources)
        self.worker = worker
        self.export = export ?? { try await worker.export($0, size: $1, format: $2, quality: $3) }
    }
    func start(size: PhotoExporter.Size, format: PhotoExporter.Format, quality: Double, save: Bool)
    {
        guard !running else { return }
        running = true
        cancelled = false
        stopReason = nil
        let pending = items.filter {
            switch outcomes[$0.id] {
            case .saved?, .shared?, .ready?: return false
            default: return true
            }
        }
        library.luts.protect(
            owner,
            ids: pending.reduce(into: Set<String>()) {
                $0.formUnion($1.recipe?.look.identifiers ?? [])
            })
        task = Task {
            await library.images.beginExport()
            for item in pending {
                if Task.isCancelled { break }
                activeID = item.id
                outcomes[item.id] = nil
                var produced: URL?
                do {
                    let url = try await export(item, size, format, quality)
                    produced = url
                    try Task.checkCancellation()
                    if save {
                        try await PhotoLibraryWriter.save(url)
                        outcomes[item.id] = .saved
                        try? FileManager.default.removeItem(at: url)
                    } else {
                        outcomes[item.id] = .ready(url)
                    }
                } catch is CancellationError {
                    if let produced { try? FileManager.default.removeItem(at: produced) }
                    break
                } catch {
                    if let produced { try? FileManager.default.removeItem(at: produced) }
                    outcomes[item.id] = .failed(error.localizedDescription)
                    // A denied destination applies to the entire batch; keep the rest pending.
                    if error is PhotoLibraryWriter.Failure { break }
                }
            }
            activeID = nil
            cancelled = Task.isCancelled
            await library.images.endExport()
            library.luts.release(owner)
            running = false
            task = nil
            if dismissed { cleanFiles() }
        }
    }
    func cancel() { task?.cancel() }
    func memoryWarning() {
        guard running else { return }
        stopReason = String(
            localized: "batch.memory_stopped",
            defaultValue:
                "Export stopped because memory was low. Choose a smaller size to continue.")
        cancel()
    }
    func close() {
        dismissed = true
        cancel()
        if !running { cleanFiles() }
    }
    func assess(size: PhotoExporter.Size) async {
        var result: [UUID: String] = [:]
        for item in items {
            let message = await worker.memoryAssessment(item, size: size)
            guard !Task.isCancelled else { return }
            result[item.id] = message
        }
        assessments = result
    }
    func shared() {
        for item in items {
            if case .ready(let url) = outcomes[item.id] {
                outcomes[item.id] = .shared
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
    func cleanFiles() {
        for url in readyURLs { try? FileManager.default.removeItem(at: url) }
        outcomes = outcomes.filter {
            if case .ready = $0.value { return false }
            return true
        }
    }
}
