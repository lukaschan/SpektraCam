import CoreGraphics
import Foundation

/// Keep disk reads and image work off the UI actor. Rebuild missing edited caches in order.
actor LibraryImages {
    let files: LibraryFiles
    private let directory: URL
    private let memory = NSCache<NSString, CGImage>()
    private let requests = ImageRequestPool<CGImage>()
    private var tail: (id: UUID, task: Task<CGImage, Error>)?
    nonisolated let resources: FilmRenderResources
    private let exportOwner = UUID()

    init(files: LibraryFiles, directory: URL) {
        self.files = files
        self.directory = directory
        resources = FilmRenderResources(directory: directory)
        memory.totalCostLimit = 32 * 1024 * 1024
    }
    func image(_ photo: LibraryPhoto, thumbnail: Bool) async throws -> CGImage {
        let maximum =
            thumbnail ? ImportedPhoto.thumbnailMaximumPixelSize : PreviewQuality.libraryMaximum
        let requestKey = "\(photo.id)-\(photo.renderKey)-\(thumbnail)-\(maximum)"
        return try await requests.value(for: requestKey) {
            try await self.load(photo, thumbnail: thumbnail, maximum: maximum)
        }
    }
    /// A viewer can show an existing grid image while its precise preview develops.
    /// This path never starts a RAW decode or rebuilds a missing thumbnail.
    func cachedThumbnail(_ photo: LibraryPhoto) async -> CGImage? {
        let key = "\(photo.id)-\(photo.renderKey)-true-\(ImportedPhoto.thumbnailMaximumPixelSize)" as NSString
        if let image = memory.object(forKey: key) { return image }
        return await files.cachedImage(photo, thumbnail: true)
    }
    private func load(_ photo: LibraryPhoto, thumbnail: Bool, maximum: Int) async throws -> CGImage
    {
        let key = "\(photo.id)-\(photo.renderKey)-\(thumbnail)-\(maximum)" as NSString
        if let image = memory.object(forKey: key) { return image }
        if let image = await files.cachedImage(photo, thumbnail: thumbnail, maximum: maximum) {
            memory.setObject(image, forKey: key, cost: image.width * image.height * 4)
            return image
        }
        let image: CGImage
        if !photo.hasEdits {
            image = try await files.originalImage(photo, thumbnail: thumbnail, maximum: maximum)
        } else {
            let previous = tail?.task
            let id = UUID()
            let job = Task {
                if let previous { _ = await previous.result }
                try Task.checkCancellation()
                return try await self.rebuild(photo, thumbnail: thumbnail, maximum: maximum)
            }
            tail = (id, job)
            defer { if tail?.id == id { tail = nil } }
            let preview = try await withTaskCancellationHandler {
                try await job.value
            } onCancel: {
                job.cancel()
            }
            image = preview
        }
        try Task.checkCancellation()
        memory.setObject(image, forKey: key, cost: image.width * image.height * 4)
        return image
    }
    private func rebuild(_ photo: LibraryPhoto, thumbnail: Bool, maximum requestedMaximum: Int)
        async throws -> CGImage
    {
        if let cached = await files.cachedImage(
            photo, thumbnail: thumbnail, maximum: requestedMaximum)
        {
            return cached
        }
        if thumbnail, let preview = await files.cachedImage(photo, thumbnail: false) {
            return try await files.storeThumbnail(preview, photo: photo)
        }
        guard let data = photo.recipeData else {
            return try await files.originalImage(photo, thumbnail: thumbnail)
        }
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: data)
        guard recipe.upstreamRevision == EditRecipe().upstreamRevision else {
            throw LibraryFiles.Failure.image
        }
        // Keep enough source pixels for a crop, up to the normal editor preview limit.
        let span = min(recipe.crop.normalizedRect.width, recipe.crop.normalizedRect.height)
        let thumbnailLimit = ImportedPhoto.thumbnailMaximumPixelSize
        let previewLimit = thumbnail ? ImportedPhoto.previewMaximumPixelSize : requestedMaximum
        let maximum =
            thumbnail
            ? min(
                previewLimit,
                max(thumbnailLimit, Int(ceil(CGFloat(thumbnailLimit) / max(span, 1e-6)))))
            : previewLimit
        let original = try await files.decodedPhoto(photo, maximum: maximum)
        let renderer = PhotoRenderer(
            source: original.preview, directory: directory,
            data: original.data, temperature: original.rawTemperature,
            lutDirectory: files.root.appendingPathComponent("LUTs"), previewMaximum: maximum,
            resources: resources, sourceType: original.sourceType,
            description: original.sourceDescription)
        let film = try await renderer.render(recipe)
        try Task.checkCancellation()
        guard let geometry = GeometryRenderer.render(film, geometry: recipe.geometry),
            let cropped = geometry.cropping(
                to: recipe.crop.pixelRect(
                    in: CGSize(width: geometry.width, height: geometry.height)))
        else { throw LibraryFiles.Failure.image }
        if thumbnail { return try await files.storeThumbnail(cropped, photo: photo) }
        try await files.storePreview(cropped, photo: photo, maximum: requestedMaximum)
        return cropped
    }
    func store(_ image: CGImage, photo: LibraryPhoto) async throws {
        try await files.storePreview(image, photo: photo)
        memory.removeAllObjects()
    }
    func discardMemory() {
        memory.removeAllObjects()
    }
    func beginEditing(owner: UUID) async { await requests.pause(owner: owner) }
    func endEditing(owner: UUID) async { await requests.resume(owner: owner) }
    func workSnapshot() async -> ImageRequestPool<CGImage>.Snapshot { await requests.snapshot }
    func beginExport() async {
        await requests.pause(owner: exportOwner)
        await files.discardPreparedPhoto()
        tail = nil
        memory.removeAllObjects()
        if !Task.isCancelled, let (_, gpu) = try? await resources.load() {
            await gpu.releaseWorkingCaches()
        }
    }
    func endExport() async { await requests.resume(owner: exportOwner) }
}
