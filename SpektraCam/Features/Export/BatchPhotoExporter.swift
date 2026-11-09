import CoreGraphics
import Foundation

nonisolated struct BatchExportItem: Identifiable, Sendable {
    let id: UUID
    let name: String
    let source: URL
    let recipe: EditRecipe?
    var width = 0
    var height = 0
}

/// One item owns all full-size buffers. Only encoded file URLs leave this worker.
actor BatchPhotoExporter {
    private let directory: URL
    private let luts: URL
    private let resources: FilmRenderResources
    init(directory: URL, luts: URL, resources: FilmRenderResources) {
        self.directory = directory
        self.luts = luts
        self.resources = resources
    }
    func memoryAssessment(_ item: BatchExportItem, size: PhotoExporter.Size) -> String? {
        guard item.width > 0, item.height > 0 else { return nil }
        let recipe = item.recipe
        let w = Double(item.width)
        let h = Double(item.height)
        let rotated = (recipe?.geometry.quarterTurns ?? 0) % 2 != 0
        let crop = recipe?.crop.normalizedRect ?? CropSelection.fullImage
        let fraction =
            max(crop.width * (rotated ? h : w), crop.height * (rotated ? w : h)) / max(w, h)
        let maximum = min(max(w, h), Double(size.maximum ?? Int.max) / max(fraction, 1e-6))
        let scale = maximum / max(w, h)
        do {
            if let recipe {
                try RenderMemoryBudget.check(
                    width: max(1, Int(ceil(w * scale))),
                    height: max(1, Int(ceil(h * scale))), recipe: recipe)
            } else {
                try PhotoSource.checkDevelopmentMemory(
                    width: max(1, Int(ceil(w * scale))),
                    height: max(1, Int(ceil(h * scale))))
            }
            return nil
        } catch { return error.localizedDescription }
    }
    func export(
        _ item: BatchExportItem, size: PhotoExporter.Size,
        format: PhotoExporter.Format, quality: Double
    ) async throws -> URL {
        try Task.checkCancellation()
        guard let recipe = item.recipe else {
            let original = OriginalPhotoExporter(source: item.source, sourceFilename: item.name)
            // This exporter owns the result until the caller takes ownership of its file.
            let result = try await original.export(size: size, format: format, quality: quality)
            return result.0
        }
        guard recipe.upstreamRevision == EditRecipe().upstreamRevision else {
            throw PhotoExporter.Failure.render
        }
        let data = try Data(contentsOf: item.source, options: .mappedIfSafe)
        guard
            let photo = ImportedPhoto.decode(
                data, maximum: 384,
                typeHint: PhotoSource.typeHint(for: item.source))
        else { throw PhotoExporter.Failure.decode }
        let renderer = PhotoRenderer(
            source: photo.preview, directory: directory, data: data,
            temperature: photo.rawTemperature, lutDirectory: luts, previewMaximum: 384,
            resources: resources, sourceType: photo.sourceType, description: photo.sourceDescription, sourceFilename: item.name)
        do {
            let result = try await renderer.export(
                recipe, size: size, format: format, quality: quality)
            await renderer.discardExport()
            return result.0
        } catch {
            await renderer.discardExport()
            throw error
        }
    }
}
