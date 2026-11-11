import CoreGraphics
import OSLog
import Observation
import SwiftUI

/// One source, one recipe, and bounded recipe history; never copies source bytes for undo.
@MainActor @Observable final class EditorSession: Identifiable, Hashable {
    let id = UUID()
    let photo: ImportedPhoto
    let luts: LUTLibrary?
    @ObservationIgnored private let uneditedRecipe: EditRecipe
    var recipe: EditRecipe { didSet { luts?.protect(id, ids: usedLUTIdentifiers) } }
    var geometryImage: UIImage
    var histogram = PhotoHistogram.empty
    var originalHistogram = PhotoHistogram.empty
    @ObservationIgnored private var filmHistogram = PhotoHistogram.empty
    var displayImage: UIImage
    var isRendering = false
    var renderFailed = false
    var isProcessingFilm = false
    var isRefiningPreview = false
    var filmRenderFailed = false
    @ObservationIgnored private var failureTask: Task<Void, Never>?
    @ObservationIgnored private static let logger = Logger(
        subsystem: "io.github.runzeni.andreavolpato-spektrafilm", category: "Rendering")
    var hasFilmPreview = false
    var isBusy: Bool { (isRendering || isProcessingFilm) && !isRefiningPreview }
    @ObservationIgnored private let filmRenderer: PhotoRenderer
    @ObservationIgnored private var edgeTask: Task<CGImage, Error>?
    @ObservationIgnored private var edgeEpoch = UUID()
    @ObservationIgnored private var filmSource: CGImage
    @ObservationIgnored private var renderedSource: CGImage
    @ObservationIgnored private var filmTask: Task<Void, Never>?
    @ObservationIgnored private var frameTask: Task<CGImage, Error>?
    @ObservationIgnored private var frameMaximum = 0
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    private var waitingToRefine = false
    @ObservationIgnored private var filmRevision: UInt64 = 0
    @ObservationIgnored private var filmEpoch = UUID()
    @ObservationIgnored private var renderedFilmRecipe: EditRecipe?
    private var renderedPreviewMaximum = 0
    var effectivePreviewMaximum = PreviewQuality.editorMaximum
    var previewWasReduced = false
    private var requestedPreviewMaximum: Int {
        interactionKey == nil && !waitingToRefine
            ? PreviewQuality.editorMaximum : min(720, PreviewQuality.editorMaximum)
    }
    private var renderedGeometry = ImageGeometry()
    private var renderedCrop = CropSelection.fullImage
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderRevision: UInt64 = 0
    @ObservationIgnored private var renderEpoch = UUID()
    private var undoStack: [EditRecipe] = []
    private var redoStack: [EditRecipe] = []
    private var lastChange = Date.distantPast
    private var lastKey = ""
    @ObservationIgnored private var interactionKey: String?
    @ObservationIgnored private var presentationInteractionKey: String?

    @ObservationIgnored var recipeDidChange: ((EditRecipe, Bool) -> Void)?

    init(
        photo: ImportedPhoto, recipe restored: EditRecipe? = nil, luts: LUTLibrary? = nil,
        resources: FilmRenderResources? = nil, sourceFilename: String? = nil
    ) {
        self.photo = photo
        self.luts = luts
        filmSource = photo.preview
        renderedSource = photo.preview
        filmRenderer = PhotoRenderer(
            source: photo.preview, directory: Bundle.main.resourceURL!, data: photo.data,
            temperature: photo.rawTemperature, lutDirectory: luts?.directory,
            resources: resources, sourceType: photo.sourceType,
            description: photo.sourceDescription, sourceFilename: sourceFilename
        )
        let original = EditorDefaults.originalRecipe(temperature: photo.rawTemperature)
        uneditedRecipe = original
        var initial = restored ?? original
        if initial.temperature == nil { initial.temperature = photo.rawTemperature }
        initial.constrainFilmEdgeCrop(imageSize: CGSize(width: photo.width, height: photo.height))
        recipe = initial
        let initialPreview = UIImage(cgImage: photo.preview)
        geometryImage = initialPreview
        displayImage = initialPreview
        if !initial.look.enabled, initial.source == EditRecipe.Source(), initial.tone.isIdentity,
            max(photo.preview.width, photo.preview.height)
                >= min(PreviewQuality.editorMaximum, max(photo.width, photo.height))
        {
            renderedFilmRecipe = initial.processingRecipe
            renderedPreviewMaximum = PreviewQuality.editorMaximum
            effectivePreviewMaximum = min(PreviewQuality.editorMaximum, max(photo.preview.width, photo.preview.height))
            hasFilmPreview = true
        }
        luts?.protect(id, ids: usedLUTIdentifiers)
        luts?.registerRemoval(id) { [weak self] ids in self?.removeLUTReferences(ids) }
    }
    private func removeLUTReferences(_ ids: Set<String>) {
        undoStack = undoStack.map { $0.removingLUTs(ids) }
        redoStack = redoStack.map { $0.removingLUTs(ids) }
        recipe = recipe.removingLUTs(ids)
        recipeDidChange?(recipe, true)
        renderFilmIfNeeded()
    }
    deinit {
        let owner = id
        let store = luts
        Task { @MainActor in store?.release(owner) }
    }
    nonisolated static func == (lhs: EditorSession, rhs: EditorSession) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var usedLUTIdentifiers: Set<String> {
        (undoStack + redoStack + [recipe]).reduce(into: Set<String>()) {
            $0.formUnion($1.look.identifiers)
        }
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasEdits: Bool {
        recipe != uneditedRecipe
    }
    func resetAll() { update(key: "reset") { $0 = uneditedRecipe } }
    func binding<Value>(_ keyPath: WritableKeyPath<EditRecipe, Value>, key: String) -> Binding<
        Value
    > {
        Binding(
            get: { self.recipe[keyPath: keyPath] },
            set: { value in
                self.update(key: key) { $0[keyPath: keyPath] = value }
            })
    }
    func setInteraction(key: String, active: Bool) {
        if active {
            settleTask?.cancel()
            settleTask = nil
            waitingToRefine = false
            failureTask?.cancel()
            filmRenderFailed = false
            interactionKey = key
            lastKey = ""
            if frameMaximum > 720, frameTask != nil {
                // A new touch takes priority over a queued high-quality refinement.
                filmRevision &+= 1
                frameTask?.cancel()
            }
        } else if interactionKey == key {
            interactionKey = nil
            // UIKit can send a final valueChanged after touch-up. Keep it in the same undo group.
            // The next touch-down starts a new group.
            scheduleRefinement()
            recipeDidChange?(recipe, true)
        }
    }
    /// Group finishing gestures without cancelling or rescheduling the film renderer.
    func setPresentationInteraction(key: String, active: Bool) {
        if active {
            presentationInteractionKey = key
            lastKey = ""
        } else if presentationInteractionKey == key {
            presentationInteractionKey = nil
            recipeDidChange?(recipe, true)
        }
    }
    func update(key: String, _ change: (inout EditRecipe) -> Void) {
        var next = recipe
        change(&next)
        next.constrainFilmEdgeCrop(imageSize: CGSize(width: photo.width, height: photo.height))
        next.removeDefaultOverrides()
        guard next != recipe else { return }
        let now = Date()
        if lastKey != key || (interactionKey != key && presentationInteractionKey != key
            && now.timeIntervalSince(lastChange) > 0.4) {
            undoStack.append(recipe)
            if undoStack.count > 100 { undoStack.removeFirst() }
        }
        redoStack.removeAll()
        lastKey = key
        lastChange = now
        let oldGeometry = recipe.geometry
        let oldRect = recipe.crop.normalizedRect
        let changedFilm = recipe.processingRecipe != next.processingRecipe
        recipe = next
        recipeDidChange?(recipe, false)
        if changedFilm {
            // Numeric entry, stock changes and switches also deserve a quick first result.
            if interactionKey == nil { scheduleRefinement() }
            renderFilm()
        }
        if oldGeometry != next.geometry || oldRect != next.crop.normalizedRect {
            isRefiningPreview = false
            renderGeometry()
        }
    }
    func selectFilm(_ stock: FilmStock) {
        update(key: "film") { $0.selectFilm(stock) }
    }
    func resetGrain() {
        update(key: "grain.reset") { recipe in
            recipe.monochromeGrain = false
            recipe.numbers = recipe.numbers.filter { !$0.key.hasPrefix("film_render.grain.") }
            recipe.flags = recipe.flags.filter { !$0.key.hasPrefix("film_render.grain.") }
        }
    }
    func export(
        size: PhotoExporter.Size, format: PhotoExporter.Format, quality: Double,
        allowOvercommit: Bool = false
    ) async throws -> (
        URL, Int, Int
    ) {
        let snapshot = recipe
        edgeTask?.cancel()
        _ = await edgeTask?.result
        settleTask?.cancel()
        settleTask = nil
        waitingToRefine = false
        await filmTask?.value
        try Task.checkCancellation()
        // Keep the visible snapshot while the sheet owns the screen. Release larger
        // intermediate proxies before allocating the full-resolution export graph.
        let previousSource = filmSource
        filmSource = photo.preview
        renderedSource = photo.preview
        geometryImage = displayImage
        renderedFilmRecipe = nil
        renderedPreviewMaximum = 0
        await GeometryWorker.shared.discard(previousSource)
        return try await filmRenderer.export(
            snapshot, size: size, format: format, quality: quality, allowOvercommit: allowOvercommit
        )
    }
    func filmEdgePreview(_ snapshot: EditRecipe, maximum: Int) async throws -> CGImage {
        edgeTask?.cancel()
        let epoch = UUID()
        edgeEpoch = epoch
        let renderer = filmRenderer
        let job = Task { try await renderer.renderFilmEdge(snapshot, maximum: maximum) }
        edgeTask = job
        defer { if edgeEpoch == epoch { edgeTask = nil } }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
    func discardExport() { Task { await filmRenderer.discardExport() } }
    func resumeAfterExport() {
        scheduleRefinement()
        renderFilmIfNeeded()
    }
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(recipe)
        restoreHistory(previous)
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(recipe)
        restoreHistory(next)
    }
    private func restoreHistory(_ saved: EditRecipe) {
        var next = saved
        next.constrainFilmEdgeCrop(imageSize: CGSize(width: photo.width, height: photo.height))
        let processingChanged = recipe.processingRecipe != next.processingRecipe
        let geometryChanged = recipe.geometry != next.geometry || recipe.crop != next.crop
        recipe = next
        recipeDidChange?(recipe, true)
        lastKey = ""
        if processingChanged {
            scheduleRefinement()
            renderFilmIfNeeded()
        }
        if processingChanged || geometryChanged { renderGeometry() }
    }
    /// One render in flight and one latest desired state. Completed frames remain visible
    /// during a drag; a continuous stream of slider events never postpones rendering.
    func renderGeometry() {
        renderRevision &+= 1
        let geometry = recipe.geometry
        let crop = recipe.crop
        if geometry.isIdentity && crop.normalizedRect == CropSelection.fullImage {
            renderTask?.cancel()
            renderTask = nil
            renderEpoch = UUID()
            if !renderedGeometry.isIdentity || renderedSource !== filmSource {
                geometryImage = UIImage(cgImage: filmSource)
            }
            renderedSource = filmSource
            histogram = filmHistogram
            displayImage = geometryImage
            renderedGeometry = geometry
            renderedCrop = crop.normalizedRect
            isRendering = false
            renderFailed = false
            return
        }
        isRendering = geometry != renderedGeometry || renderedSource !== filmSource
        renderFailed = false
        guard renderTask == nil else { return }
        let epoch = UUID()
        renderEpoch = epoch
        renderTask = Task {
            while !Task.isCancelled {
                let source = filmSource
                let revision = renderRevision
                let geometry = recipe.geometry
                let crop = recipe.crop
                let frame = await GeometryWorker.shared.render(
                    source, geometry: geometry, crop: crop)
                guard !Task.isCancelled, renderEpoch == epoch else { return }
                guard let frame else {
                    if revision != renderRevision { continue }
                    renderFailed = true
                    isRendering = false
                    renderTask = nil
                    return
                }
                if renderedGeometry != geometry || renderedSource !== source {
                    geometryImage = UIImage(cgImage: frame.geometry)
                }
                displayImage = UIImage(cgImage: frame.display)
                histogram = frame.histogram
                renderedSource = source
                renderedGeometry = geometry
                renderedCrop = crop.normalizedRect
                isRendering = recipe.geometry != geometry || renderedSource !== filmSource
                if revision == renderRevision {
                    renderTask = nil
                    return
                }
                await Task.yield()
            }
        }
    }

    func resumeRendering() {
        // Saved edits need the same quick first frame as a new adjustment. This also
        // prepares the interactive cache before a user touches the first slider.
        if !hasFilmPreview && filmTask == nil { scheduleRefinement() }
        let source = photo.preview
        Task {
            let stats = await HistogramWorker.shared.make(source)
            originalHistogram = stats
            if !recipe.look.enabled, recipe.source == EditRecipe.Source(), recipe.tone.isIdentity,
                filmSource === source
            {
                filmHistogram = stats
                if recipe.geometry.isIdentity && recipe.crop.normalizedRect == CropSelection.fullImage {
                    histogram = stats
                }
            }
        }
        renderFilmIfNeeded()
        if renderedSource !== filmSource || recipe.geometry != renderedGeometry
            || recipe.crop.normalizedRect != renderedCrop
        {
            renderGeometry()
        }
    }
    private func scheduleRefinement() {
        settleTask?.cancel()
        waitingToRefine = true
        settleTask = Task {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            waitingToRefine = false
            settleTask = nil
            renderFilmIfNeeded()
        }
    }
    private func renderFilmIfNeeded() {
        if filmTask != nil || renderedFilmRecipe != recipe.processingRecipe
            || renderedPreviewMaximum != requestedPreviewMaximum
        {
            renderFilm()
        } else {
            filmRevision &+= 1
            failureTask?.cancel()
            filmRenderFailed = false
        }
    }

    /// Keep one active GPU frame and the latest desired recipe, without debouncing a continuous drag.
    func renderFilm() {
        filmRevision &+= 1
        failureTask?.cancel()
        filmRenderFailed = false
        isProcessingFilm = true
        isRefiningPreview = hasFilmPreview && renderedFilmRecipe == recipe.processingRecipe
        guard filmTask == nil else { return }
        let epoch = UUID()
        filmEpoch = epoch
        filmTask = Task {
            while !Task.isCancelled {
                let revision = filmRevision
                let requested = recipe.processingRecipe
                let maximum = requestedPreviewMaximum
                isRefiningPreview = hasFilmPreview && renderedFilmRecipe == requested
                frameMaximum = maximum
                do {
                    let image: CGImage
                    let actualMaximum: Int
                    do {
                        let renderer = filmRenderer
                        let job = Task { try await renderer.render(requested, maximum: maximum) }
                        frameTask = job
                        image = try await job.value
                        guard !Task.isCancelled, filmEpoch == epoch else { return }
                        frameTask = nil
                        actualMaximum = maximum
                    } catch is RenderMemoryBudget.Failure where maximum > 720 {
                        guard !Task.isCancelled, filmEpoch == epoch else { return }
                        frameTask = nil
                        image = try await filmRenderer.render(requested, maximum: 720)
                        actualMaximum = 720
                    }
                    let stats = await HistogramWorker.shared.make(image)
                    guard !Task.isCancelled, filmEpoch == epoch else { return }
                    // One render is in flight: publish the latest completed proxy while
                    // the loop advances to the newest request. Epoch guards reject cancelled work.
                    let refiningCurrent = hasFilmPreview && renderedFilmRecipe == requested
                        && requested == recipe.processingRecipe
                        && renderedGeometry == recipe.geometry && renderedCrop == recipe.crop.normalizedRect
                    filmSource = image
                    filmHistogram = stats
                    renderedFilmRecipe = requested
                    renderedPreviewMaximum = maximum
                    effectivePreviewMaximum = actualMaximum
                    previewWasReduced = actualMaximum < maximum
                    hasFilmPreview = true
                    isRefiningPreview = refiningCurrent
                    renderGeometry()
                } catch {
                    guard !Task.isCancelled, filmEpoch == epoch else { return }
                    frameTask = nil
                    if revision != filmRevision { continue }
                    Self.logger.error(
                        "Preview failed: \(String(describing: error), privacy: .public), film \(requested.filmID, privacy: .public)"
                    )
                    if interactionKey == nil {
                        failureTask = Task {
                            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                            guard !Task.isCancelled, filmEpoch == epoch, filmRevision == revision
                            else {
                                return
                            }
                            filmRenderFailed = true
                        }
                    }
                }
                if revision == filmRevision {
                    filmTask = nil
                    isProcessingFilm = false
                    return
                }
                await Task.yield()
            }
        }
    }

    func cancelRendering() {
        edgeEpoch = UUID()
        edgeTask?.cancel()
        edgeTask = nil
        settleTask?.cancel()
        settleTask = nil
        waitingToRefine = false
        frameTask?.cancel()
        frameTask = nil
        failureTask?.cancel()
        filmTask?.cancel()
        filmTask = nil
        filmEpoch = UUID()
        isProcessingFilm = false
        isRefiningPreview = false
        renderTask?.cancel()
        renderTask = nil
        renderEpoch = UUID()
        isRendering = false
        let source = filmSource
        Task { await GeometryWorker.shared.discard(source) }
        Task { await filmRenderer.releasePreviewCaches() }
    }
}

/// One active render; cancelled queued requests are skipped. A crop never reruns rotation.
private actor GeometryWorker {
    struct Frame: Sendable { let geometry: CGImage, display: CGImage, histogram: PhotoHistogram }
    static let shared = GeometryWorker()
    private var cachedSource: CGImage?
    private var cachedGeometry: ImageGeometry?
    private var cachedImage: CGImage?

    func render(_ source: CGImage, geometry: ImageGeometry, crop: CropSelection) -> Frame? {
        guard !Task.isCancelled else { return nil }
        let image: CGImage
        if cachedSource === source, cachedGeometry == geometry, let cachedImage {
            image = cachedImage
        } else {
            guard let rendered = GeometryRenderer.render(source, geometry: geometry) else {
                return nil
            }
            image = rendered
            cachedSource = source
            cachedGeometry = geometry
            cachedImage = image
        }
        guard !Task.isCancelled else { return nil }
        if crop.normalizedRect == CropSelection.fullImage {
            return Frame(geometry: image, display: image, histogram: PhotoHistogram.make(image))
        }
        guard
            let display = image.cropping(
                to: crop.pixelRect(in: CGSize(width: image.width, height: image.height)))
        else { return nil }
        return Frame(geometry: image, display: display, histogram: PhotoHistogram.make(display))
    }
    func discard(_ source: CGImage) {
        guard cachedSource === source else { return }
        cachedSource = nil
        cachedGeometry = nil
        cachedImage = nil
    }
}
