import Foundation

/// Share model setup and one serial GPU worker across library, editor and export.
actor FilmRenderResources {
    private let directory: URL
    private var model: ModelLibrary?
    private var gpu: MetalFilmPipeline?
    private var pipelineKey: EditRecipe?
    private var preparedPipeline: FilmPipeline?

    init(directory: URL) { self.directory = directory }

    func load() throws -> (ModelLibrary, MetalFilmPipeline) {
        if model == nil { model = try ModelLibrary(directory: directory) }
        if gpu == nil {
            let sources = try ["ColorPipeline", "Spatial", "Grain", "Diffusion", "FilmPipeline"].map {
                try String(contentsOf: directory.appendingPathComponent($0 + ".metalSource"), encoding: .utf8)
            }
            gpu = try MetalFilmPipeline(sources: sources)
        }
        return (model!, gpu!)
    }

    /// Source decode and display changes do not alter the photographic material setup.
    /// Keep one immutable setup across frames and editor visits; no image buffers live here.
    func pipeline(_ recipe: EditRecipe) throws -> FilmPipeline {
        var key = recipe.processingRecipe
        key.source = EditRecipe.Source()
        key.temperature = nil
        key.mix = 1
        key.tone = EditRecipe.Tone()
        key.look.first = EditRecipe.LUTSlot()
        key.look.second = EditRecipe.LUTSlot(mix: 0)
        if pipelineKey == key, let preparedPipeline {
            return try FilmPipeline(prepared: preparedPipeline, tone: recipe.tone.rawStage)
        }
        let (library, _) = try load()
        let result = try FilmPipeline(library: library, recipe: key)
        pipelineKey = key
        preparedPipeline = result
        return try FilmPipeline(prepared: result, tone: recipe.tone.rawStage)
    }
}
