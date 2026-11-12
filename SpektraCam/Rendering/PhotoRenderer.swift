import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Owns one source and one GPU worker. Preview input, baseline metering and the latest film
/// frame are cached independently. Mix reuses the film frame; export uses original bytes.
actor PhotoRenderer {
    private let source: CGImage, data: Data?, initialTemperature: Double?
    private let sourceType: String?
    private let sourceFilename: String?
    private let sourceDescription: PhotoSource.Description?
    private final class PreviewState {
        let maximum: Int
        init(maximum: Int) { self.maximum = maximum }
        let decoder = SourceImageRenderer.Decoder()
        var neutralKey: EditRecipe.Source?
        var neutralTemperature: Double?
        var neutralImage: CGImage?
        var opticsKey: EditRecipe?
        var opticsSize = CGSize.zero
        var opticsImage: CGImage?
        var grainKey: EditRecipe?
        var grainSize = CGSize.zero
        var grainImages: (CGImage, CGImage)?
        var previousMode: EditRecipe.LookMode?
        var baseline: SourceImageRenderer.Input?
        var baselineImage: CIImage?
        var input: SourceImageRenderer.Input?
        var inputKey: EditRecipe.Source?
        var inputTemperature: Double?
        var inputLookMode: EditRecipe.LookMode?
        var meter: MeteringCore.Image?
        var meteredEV = [String: Double]()
        var filmRecipe: EditRecipe?
        var filmImage: CGImage?
    }
    private var preview: PreviewState
    // Finishing must not evict Develop's scene/LUT cache or meter the padded canvas.
    private var edgeMetering = PreviewState(maximum: 720)
    // At most the active and one alternate resolution. A drag cannot evict the settled
    // source/film cache, and a 2160 px setting does not create an unbounded image ladder.
    private var alternatePreview: (maximum: Int, state: PreviewState)?
    private var previewMaximum: Int
    private let previewLimit: Int
    private let renderResources: FilmRenderResources
    private let lutDirectory: URL?
    private var cubes: [String: CubeLUT] = [:]
    private var exportKey: EditRecipe?
    private var exportSize: PhotoExporter.Size?
    private var exportImage: CGImage?

    init(
        source: CGImage, directory: URL, data: Data? = nil, temperature: Double? = nil,
        lutDirectory: URL? = nil, previewMaximum: Int = PreviewQuality.editorMaximum,
        resources: FilmRenderResources? = nil,
        sourceType: String? = nil, description: PhotoSource.Description? = nil,
        sourceFilename: String? = nil
    ) {
        self.sourceFilename = sourceFilename
        self.source = source
        self.previewMaximum = previewMaximum
        preview = PreviewState(maximum: previewMaximum)
        previewLimit = previewMaximum
        renderResources = resources ?? FilmRenderResources(directory: directory)
        self.data = data
        let description = description ?? data.flatMap { PhotoSource.describe($0, typeHint: sourceType) }
        self.sourceDescription = description
        self.sourceType = description?.type ?? sourceType
        initialTemperature = temperature ?? description?.temperature
        self.lutDirectory = lutDirectory
    }
    private func baselineInput(state: PreviewState? = nil) throws -> SourceImageRenderer.Input {
        let cache = state ?? preview
        if let baseline = cache.baseline { return baseline }
        var recipe = EditRecipe()
        recipe.look.mode = cache.inputLookMode ?? .spektrafilm
        recipe.temperature = initialTemperature
        let result = try SourceImageRenderer.prepare(
            data: data, fallback: source, recipe: recipe, maximum: cache.maximum,
            sourceType: sourceType, description: sourceDescription, decoder: cache.decoder)
        cache.baseline = result
        if sourceDescription?.isRAW != true { cache.baselineImage = SourceImageRenderer.image(result) }
        return result
    }
    private func exposure(_ recipe: EditRecipe, library: ModelLibrary, state: PreviewState? = nil) throws -> Double {
        let cache = state ?? preview
        guard recipe.flag("camera.auto_exposure") else { return 0 }
        let method = recipe.choice("camera.auto_exposure_method")
        if let value = cache.meteredEV[method] { return value }
        if cache.meter == nil {
            let baseline = try baselineInput(state: cache)
            let y = ModelLibrary.vector(library.index.meteringY)
            let luminance = baseline.pixels.map {
                Double($0.x) * y.x + Double($0.y) * y.y + Double($0.z) * y.z
            }
            cache.meter = try MeteringCore.Image(
                width: baseline.width, height: baseline.height, luminance: luminance
            ).smallPreview()
        }
        let value = cache.meter!.exposureEV(method: method)
        cache.meteredEV[method] = value
        return value
    }
    private func selectInputMode(_ mode: EditRecipe.LookMode) {
        if preview.inputLookMode != mode {
            // Film/RAW and SDR photo-LUT input have different rendering intents, including HEIF gain maps.
            preview.baseline = nil
            preview.baselineImage = nil
            preview.input = nil
            preview.meter = nil
            preview.meteredEV.removeAll()
        }
        preview.inputLookMode = mode
    }
    private func previewInput(_ recipe: EditRecipe) throws -> SourceImageRenderer.Input {
        selectInputMode(recipe.inputMode)
        if preview.inputKey == recipe.source, preview.inputTemperature == recipe.temperature, let input = preview.input {
            return input
        }
        let result: SourceImageRenderer.Input
        if recipe.source == EditRecipe.Source(), recipe.temperature == initialTemperature {
            result = try baselineInput()
        } else {
            let canReuse = sourceDescription?.isRAW != true
            if canReuse { _ = try baselineInput() }
            result = try SourceImageRenderer.prepare(
                data: canReuse ? nil : data, fallback: source, recipe: recipe,
                maximum: previewMaximum,
                renderedSource: canReuse ? preview.baselineImage : nil, sourceType: sourceType,
                description: sourceDescription, decoder: preview.decoder)
        }
        preview.input = result
        preview.inputKey = recipe.source
        preview.inputTemperature = recipe.temperature
        return result
    }
    func render(_ recipe: EditRecipe, maximum: Int? = nil) async throws -> CGImage {
        try Task.checkCancellation()
        let requested = min(previewLimit, maximum ?? previewLimit)
        if requested != previewMaximum {
            let previous = (maximum: previewMaximum, state: preview)
            preview = alternatePreview?.maximum == requested
                ? alternatePreview!.state : PreviewState(maximum: requested)
            alternatePreview = previous
            previewMaximum = requested
        }
        let width = sourceDescription?.width ?? source.width
        let height = sourceDescription?.height ?? source.height
        let scale = min(1, Double(requested) / Double(max(width, height)))
        do {
            try RenderMemoryBudget.check(
                width: max(1, Int(ceil(Double(width) * scale))),
                height: max(1, Int(ceil(Double(height) * scale))), recipe: recipe)
        } catch {
            // The alternate is disposable. Do not keep it at the cost of an active preview.
            guard alternatePreview != nil else { throw error }
            alternatePreview = nil
            try RenderMemoryBudget.check(
                width: max(1, Int(ceil(Double(width) * scale))),
                height: max(1, Int(ceil(Double(height) * scale))), recipe: recipe)
        }
        let input = try previewInput(recipe)
        try RenderMemoryBudget.check(width: input.width, height: input.height, recipe: recipe)
        if !recipe.look.enabled {
            return try neutralFrame(input, recipe: recipe)
        }
        let (library, gpu) = try await renderResources.load()
        try Task.checkCancellation()
        if preview.previousMode != recipe.look.mode {
            preview.filmRecipe = nil
            preview.filmImage = nil
            preview.opticsKey = nil
            preview.opticsImage = nil
            preview.grainKey = nil
            preview.grainImages = nil
            preview.previousMode = recipe.look.mode
        }
        return try await frame(input, recipe: recipe, library: library, gpu: gpu, preview: true, state: preview)
    }
    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private var tiling: MetalFilmPipeline.Tiling { .fitting(available: ImageMemoryAllowance.available) }
    /// Storage for a frame that renders in tiles: a full-size export's own store, or a copy of a
    /// preview whose diffusion transform would not fit as one frame.
    private func tileStore(
        _ input: SourceImageRenderer.Input, recipe: EditRecipe, edge: FilmEdgeGeometry? = nil
    ) throws -> PixelStore? {
        if let store = input.store { return store }
        guard
            RenderMemoryBudget.rendersInTiles(
                width: input.width, height: input.height, recipe: recipe,
                pixelPitchMicrometers: edge?.pixelPitchMicrometers)
        else { return nil }
        let store = try PixelStore(width: input.width, height: input.height, format: .float)
        input.pixels.withUnsafeBytes {
            store.base.copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
        return store
    }
    /// Film render of a preview-size array, or of a full-size store rendered in tiles.
    /// `finished` asks a tiled render for the final 8-bit image when no grading follows.
    private func filmImage(
        _ input: SourceImageRenderer.Input, pipeline: FilmPipeline, gpu: MetalFilmPipeline,
        autoExposureEV: Double, edge: FilmEdgeGeometry? = nil, finished: Bool = false
    ) async throws -> CGImage {
        guard let store = try tileStore(input, recipe: pipeline.recipe, edge: edge) else {
            return try await gpu.processImage(
                input.pixels, width: input.width, height: input.height, pipeline: pipeline,
                autoExposureEV: autoExposureEV, edge: edge)
        }
        let result = try await gpu.processImage(
            store, pipeline: pipeline, autoExposureEV: autoExposureEV, edge: edge,
            format: finished ? .byte : .float, tiling: tiling)
        return try result.image(
            colorSpace: CGColorSpace(name: finished ? CGColorSpace.sRGB : CGColorSpace.extendedSRGB)!)
    }
    private func neutralFrame(_ input: SourceImageRenderer.Input, recipe: EditRecipe) throws -> CGImage {
        try ToneRenderer.render(SourceImageRenderer.workingImage(input), tone: recipe.tone)
    }
    private func applications(_ recipe: EditRecipe) throws -> [CubeLUT.Application] {
        var active: [String: CubeLUT] = [:]
        var result: [CubeLUT.Application] = []
        for slot in [recipe.look.first, recipe.look.second] {
            guard let id = slot.id, slot.mix > 0 else { continue }
            guard let lutDirectory else { throw CubeLUT.Failure.missing }
            let cube = try active[id] ?? cubes[id] ?? CubeLUT.load(id: id, directory: lutDirectory)
            active[id] = cube
            result.append(.init(cube: cube, mix: slot.mix))
        }
        cubes = active
        return result
    }
    private func effectFrames(
        _ input: SourceImageRenderer.Input, recipe: EditRecipe,
        library: ModelLibrary, gpu: MetalFilmPipeline, preview: Bool, state: PreviewState
    ) async throws -> (CGImage, CGImage?, CGImage?) {
        let cache = state
        var physical = EditRecipe()
        // The carrier uses film optics, but its RAW controls share the LUT source reference.
        physical.look.mode = .lut
        let prefixes = [
            "film_render.grain.", "film_render.halation.", "camera.diffusion_filter.",
            "enlarger.diffusion_filter.",
        ]
        physical.numbers = recipe.numbers.filter { entry in
            prefixes.contains { entry.key.hasPrefix($0) }
        }
        physical.flags = recipe.flags.filter { entry in
            prefixes.contains { entry.key.hasPrefix($0) }
        }
        physical.choices = recipe.choices.filter { entry in
            prefixes.contains { entry.key.hasPrefix($0) }
        }
        physical.numbers["camera.film_format_mm"] = recipe.number("camera.film_format_mm")
        physical.monochromeGrain = false
        physical.tone = recipe.tone.rawStage
        physical.source = recipe.source
        physical.temperature = recipe.temperature
        // Scatter is an energy mixture in RGB. Extrapolating it creates negative edge light.
        physical.numbers["film_render.halation.scatter_amount"] = min(
            max(physical.number("film_render.halation.scatter_amount"), 0), 1)
        let size = CGSize(width: input.width, height: input.height)
        let opticalFlags = [
            "film_render.halation.active", "camera.diffusion_filter.active",
            "enlarger.diffusion_filter.active",
        ]
        var optics = physical
        optics.numbers = optics.numbers.filter { !$0.key.hasPrefix("film_render.grain.") }
        optics.flags = optics.flags.filter { !$0.key.hasPrefix("film_render.grain.") }
        optics.flags["film_render.grain.active"] = false
        let source: CGImage
        if preview, cache.opticsKey == optics, cache.opticsSize == size, let image = cache.opticsImage {
            source = image
        } else {
            if opticalFlags.contains(where: { optics.flag($0) }) || !optics.tone.rawStage.isIdentity
            {
                let pipeline = try await renderResources.pipeline(optics)
                if let store = try tileStore(input, recipe: pipeline.recipe) {
                    source = try await gpu.processOptics(store, pipeline: pipeline, tiling: tiling)
                        .image(colorSpace: Self.linear)
                } else {
                    source = try await gpu.processOptics(
                        input.pixels, width: input.width, height: input.height,
                        pipeline: pipeline)
                }
            } else {
                source = try SourceImageRenderer.workingImage(input)
            }
            if preview {
                cache.opticsKey = optics
                cache.opticsSize = size
                cache.opticsImage = source
            }
        }
        var grain = physical
        grain.numbers = grain.numbers.filter {
            $0.key.hasPrefix("film_render.grain.") || $0.key == "camera.film_format_mm"
        }
        grain.flags = grain.flags.filter { $0.key.hasPrefix("film_render.grain.") }
        grain.choices = [:]
        for flag in opticalFlags { grain.flags[flag] = false }
        grain.flags["print_render.glare.active"] = false
        let noise: (CGImage, CGImage)?
        if !grain.flag("film_render.grain.active") {
            noise = nil
            if preview {
                cache.grainImages = nil
                cache.grainKey = nil
            }
        } else if preview, cache.grainKey == grain, cache.grainSize == size, let frames = cache.grainImages {
            noise = frames
        } else {
            let exposure = try exposure(grain, library: library)
            let pipeline = try await renderResources.pipeline(grain)
            if let store = input.store {
                let pair = try await gpu.processGrainPair(
                    store, pipeline: pipeline, autoExposureEV: exposure, tiling: tiling)
                noise = try (
                    pair.0.image(colorSpace: Self.linear), pair.1.image(colorSpace: Self.linear)
                )
            } else {
                noise = try await gpu.processGrainPair(
                    input.pixels, width: input.width, height: input.height,
                    pipeline: pipeline, autoExposureEV: exposure)
            }
            if preview {
                cache.grainKey = grain
                cache.grainSize = size
                cache.grainImages = noise
            }
        }
        return (source, noise?.0, noise?.1)
    }

    private func frame(
        _ input: SourceImageRenderer.Input, recipe: EditRecipe,
        library: ModelLibrary, gpu: MetalFilmPipeline, preview: Bool, state: PreviewState? = nil
    ) async throws -> CGImage {
        let cache = state ?? PreviewState(maximum: previewMaximum)
        var recipe = recipe
        recipe.numbers["film_render.halation.scatter_amount"] = min(
            max(recipe.number("film_render.halation.scatter_amount"), 0), 1)
        if recipe.look.mode == .lut {
            let frames = try await effectFrames(
                input, recipe: recipe, library: library, gpu: gpu, preview: preview, state: cache)
            let residual: (CGImage, CGImage)? = frames.1.flatMap { dirty in
                frames.2.map { (dirty, $0) }
            }
            return try ToneRenderer.render(
                frames.0, tone: recipe.tone.outputStage, luts: applications(recipe),
                residual: residual,
                monochromeResidual: recipe.monochromeGrain)
        }
        var key = recipe.processingRecipe
        key.mix = 1
        key.tone = recipe.tone.rawStage
        key.look = EditRecipe.Look()
        let film: CGImage
        if preview, cache.filmRecipe == key, let cached = cache.filmImage {
            film = cached
        } else {
            let pipeline = try await renderResources.pipeline(recipe)
            // With nothing to grade afterwards, a tiled render writes the finished 8-bit image.
            film = try await filmImage(
                input, pipeline: pipeline, gpu: gpu,
                autoExposureEV: exposure(recipe, library: library, state: cache),
                finished: recipe.mix >= 1 && recipe.tone.outputStage.isIdentity)
            if preview {
                cache.filmRecipe = key
                cache.filmImage = film
            }
        }
        try Task.checkCancellation()
        let mixed: CGImage
        if recipe.mix >= 1 {
            mixed = film
        } else {
            // Mix endpoints share output reference white, not merely a linear transfer curve.
            // Scene light belongs inside the film model; the zero endpoint is a developed photo.
            let neutral: CGImage
            if preview, cache.neutralKey == recipe.source, cache.neutralTemperature == recipe.temperature,
                let cached = cache.neutralImage
            {
                neutral = cached
            } else {
                let developed = try SourceImageRenderer.prepare(
                    data: data, fallback: source, recipe: recipe,
                    maximum: max(input.width, input.height), sourceType: sourceType,
                    intent: .developedPhoto, description: sourceDescription,
                    decoder: preview ? cache.decoder : nil, allowsStore: !preview)
                neutral = try SourceImageRenderer.workingImage(developed)
                if preview {
                    cache.neutralKey = recipe.source
                    cache.neutralTemperature = recipe.temperature
                    cache.neutralImage = neutral
                }
            }
            let rawSource = try ToneRenderer.working(neutral, tone: recipe.tone.rawStage)
            mixed = try SourceImageRenderer.blend(
                film: film, sourceImage: rawSource, amount: recipe.mix)
        }
        return try ToneRenderer.render(mixed, tone: recipe.tone.outputStage)
    }

    /// Sharp pixels for the visible part of a zoomed preview.
    struct Detail: @unchecked Sendable {
        let image: CGImage
        /// Where the image lies in the displayed (turned and cropped) photo, in unit coordinates.
        let rect: CGRect
    }
    private let detailDecoder = SourceImageRenderer.Decoder()
    /// Render only what is on screen, at the resolution the zoom needs. `visible` is the part
    /// of the displayed photo in view (unit coordinates, origin top left); `longEdge` is how
    /// many pixels the whole displayed photo's long edge would need at this zoom.
    /// Wide effects come from a low-resolution capture of the whole frame that is prepared once
    /// per edit, so panning only pays for the tiles it exposes. Returns nil when the regular
    /// preview is already sharp enough or the recipe needs the whole-frame route.
    func renderDetail(_ original: EditRecipe, visible: CGRect, longEdge: Int) async throws -> Detail? {
        try Task.checkCancellation()
        guard let data, original.look.enabled, original.look.mode == .spektrafilm,
            original.mix >= 1, original.filmEdgeLayout == nil,
            original.printLayout.map(\.isIdentity) ?? true,
            original.geometry.straightenDegrees == 0
        else { return nil }
        var recipe = original
        recipe.numbers["film_render.halation.scatter_amount"] = min(
            max(recipe.number("film_render.halation.scatter_amount"), 0), 1)
        let nativeWidth = sourceDescription?.width ?? source.width
        let nativeHeight = sourceDescription?.height ?? source.height
        let oriented = recipe.geometry.quarterTurns % 2 == 0
            ? CGSize(width: nativeWidth, height: nativeHeight)
            : CGSize(width: nativeHeight, height: nativeWidth)
        let crop = recipe.crop.pixelRect(in: oriented)
        guard crop.width >= 1, crop.height >= 1 else { return nil }
        // Zoom levels halve the native size, so a level's capture is reused while panning.
        let wanted = Double(longEdge) / Double(max(crop.width, crop.height))
        var scale = 1.0
        while scale / 2 >= wanted { scale /= 2 }
        let maximum = Int(ceil(Double(max(nativeWidth, nativeHeight)) * scale))
        guard maximum > previewMaximum * 5 / 4 else { return nil }
        func decode(_ region: SourceImageRenderer.Region?, target: CGSize? = nil, long: Int)
            throws -> SourceImageRenderer.Input
        {
            try SourceImageRenderer.prepare(
                data: data, fallback: source, recipe: recipe, maximum: long,
                sourceType: sourceType, intent: .sceneLinear, description: sourceDescription,
                decoder: region == nil ? nil : detailDecoder, targetSize: target, region: region)
        }
        let size = try decode(.measure, long: maximum)
        let width = size.width, height = size.height
        let tiling = self.tiling
        let factor = tiling.resolvedFactor(width: width, height: height)
        let (library, gpu) = try await renderResources.load()
        let pipeline = try await renderResources.pipeline(recipe)
        let autoEV = try exposure(recipe, library: library, state: preview)
        var prepared = try await gpu.prepareRegion(
            width: width, height: height, factor: factor, pipeline: pipeline,
            autoExposureEV: autoEV, tiling: tiling, proxy: nil)
        if prepared == nil {
            let proxyWidth = (width + factor - 1) / factor, proxyHeight = (height + factor - 1) / factor
            let proxy = try decode(
                nil, target: CGSize(width: proxyWidth, height: proxyHeight),
                long: max(proxyWidth, proxyHeight))
            try Task.checkCancellation()
            prepared = try await gpu.prepareRegion(
                width: width, height: height, factor: factor, pipeline: pipeline,
                autoExposureEV: autoEV, tiling: tiling, proxy: proxy.pixels)
        }
        guard let halo = prepared else { throw PhotoExporter.Failure.render }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let shown = visible.intersection(unit)
        guard !shown.isEmpty else { return nil }
        let turned = CGRect(
            x: (crop.minX + shown.minX * crop.width) / oriented.width,
            y: (crop.minY + shown.minY * crop.height) / oriented.height,
            width: shown.width * crop.width / oriented.width,
            height: shown.height * crop.height / oriented.height)
        let from = recipe.geometry.sourceRect(forOriented: turned)
        let x0 = min(max(Int(floor(from.minX * Double(width))), 0), width - 1)
        let y0 = min(max(Int(floor(from.minY * Double(height))), 0), height - 1)
        let x1 = min(max(Int(ceil(from.maxX * Double(width))), x0 + 1), width)
        let y1 = min(max(Int(ceil(from.maxY * Double(height))), y0 + 1), height)
        let sx0 = max(0, x0 - halo), sy0 = max(0, y0 - halo)
        let sx1 = min(width, x1 + halo), sy1 = min(height, y1 + halo)
        let part = try decode(
            .rect(x: sx0, y: sy0, width: sx1 - sx0, height: sy1 - sy0), long: maximum)
        guard let store = part.store else { throw PhotoExporter.Failure.render }
        try Task.checkCancellation()
        let key = MetalFilmPipeline.RegionKey(
            recipe: pipeline.recipe, width: width, height: height, factor: factor,
            autoExposureEV: autoEV, seed: 0)
        let result = try await gpu.processRegion(
            store, origin: (sx0, sy0), region: (x0, y0, x1 - x0, y1 - y0), key: key,
            pipeline: pipeline)
        try Task.checkCancellation()
        let film = try result.image(colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!)
        let finished = try ToneRenderer.render(film, tone: recipe.tone.outputStage)
        guard let image = GeometryRenderer.render(finished, geometry: recipe.geometry.orientationOnly)
        else { throw PhotoExporter.Failure.render }
        let back = recipe.geometry.orientedRect(
            forSource: CGRect(
                x: Double(x0) / Double(width), y: Double(y0) / Double(height),
                width: Double(x1 - x0) / Double(width), height: Double(y1 - y0) / Double(height)))
        return Detail(
            image: image,
            rect: CGRect(
                x: (back.minX * oriented.width - crop.minX) / crop.width,
                y: (back.minY * oriented.height - crop.minY) / crop.height,
                width: back.width * oriented.width / crop.width,
                height: back.height * oriented.height / crop.height))
    }

    /// Saved viewer/library presentation uses the same edge and paper finishing as export.
    func renderPresentation(_ recipe: EditRecipe, maximum: Int) async throws -> CGImage {
        let photograph: CGImage
        if recipe.filmEdgeLayout != nil {
            photograph = try await renderFilmEdge(recipe, maximum: maximum)
        } else {
            let developed = try await render(recipe, maximum: maximum)
            guard let transformed = GeometryRenderer.render(developed, geometry: recipe.geometry),
                  let cropped = transformed.cropping(to: recipe.crop.pixelRect(in: CGSize(width: transformed.width, height: transformed.height)))
            else { throw PhotoExporter.Failure.render }
            photograph = cropped
        }
        if let layout = recipe.printLayout, !layout.isIdentity {
            return try PrintCompositor.render(photograph, layout: layout, maximum: maximum)
        }
        return photograph
    }

    /// Complete capture-support presentation, before paper placement and final file encoding.
    /// The final long edge includes the rebate; native export never grows the canvas silently.
    func renderFilmEdge(_ original: EditRecipe, maximum: Int?, allowOvercommit: Bool = false) async throws -> CGImage {
        try Task.checkCancellation()
        guard let layout = original.filmEdgeLayout else { throw PhotoExporter.Failure.render }
        let dimensions = sourceDescription.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: source.width, height: source.height)
        var recipe = original
        recipe.constrainFilmEdgeCrop(imageSize: dimensions)
        let oriented = original.geometry.quarterTurns % 2 == 0 ? dimensions
            : CGSize(width: dimensions.height, height: dimensions.width)
        let crop = recipe.crop.pixelRect(in: oriented)
        let nativeLong = max(1, Int(max(crop.width, crop.height)))
        let long = min(nativeLong, maximum ?? nativeLong)
        recipe.tone.monochrome = false
        let material = FilmEdgeRenderer.materialRecipe(recipe)
        // Holes follow the source stock: cine camera negatives are BH-1866, still film KS-1870.
        guard let geometry = FilmEdgeGeometry(imageSize: crop.size, layout: layout, longEdge: long,
                                              perforation: .source(filmID: material.filmID))
        else { throw PhotoExporter.Failure.render }
        let originalLong = max(dimensions.width, dimensions.height)
        let decodeMaximum = min(Int(originalLong), max(1, Int(ceil(originalLong * max(geometry.gate.width, geometry.gate.height) / Double(nativeLong)))))
        let decodeScale = Double(decodeMaximum) / originalLong
        try RenderMemoryBudget.check(width: max(1, Int(ceil(dimensions.width * decodeScale))),
            height: max(1, Int(ceil(dimensions.height * decodeScale))), recipe: material, allowOvercommit: allowOvercommit,
            pixelPitchMicrometers: geometry.pixelPitchMicrometers)
        try RenderMemoryBudget.check(width: geometry.width, height: geometry.height,
            recipe: material, allowOvercommit: allowOvercommit, pixelPitchMicrometers: geometry.pixelPitchMicrometers)
        let (library, gpu) = try await renderResources.load()
        let autoEV = try exposure(material, library: library, state: edgeMetering)
        let input = try SourceImageRenderer.prepare(data: data, fallback: source, recipe: material,
            maximum: decodeMaximum, sourceType: sourceType, intent: .sceneLinear,
            description: sourceDescription, framing: recipe,
            targetSize: CGSize(width: max(1, geometry.gate.width.rounded()), height: max(1, geometry.gate.height.rounded())),
            allowsStore: true)
        let pipeline = try await renderResources.pipeline(material)
        let composes = material.processingRecipe != recipe.processingRecipe
        // A composed centre fades through the soft gate itself, so the material graph's scene must
        // stop inside the penumbra; otherwise its own developed image shows as a rim.
        var materialGeometry = geometry
        materialGeometry.erodesGate = composes
        var image = try await filmImage(
            FilmEdgeRenderer.padded(input, geometry: geometry), pipeline: pipeline, gpu: gpu,
            autoExposureEV: autoEV, edge: materialGeometry,
            finished: !composes && original.tone.outputStage.isIdentity)
        try Task.checkCancellation()
        if composes {
            // Keep LUTs, disabled Develop and every manual cross-family choice exactly as selected.
            // Release FFT work before the second graph; the completed support bitmap is retained.
            await gpu.releaseWorkingCaches()
            let centerInput = try SourceImageRenderer.prepare(data: data, fallback: source, recipe: recipe,
                maximum: decodeMaximum, sourceType: sourceType, description: sourceDescription, allowsStore: true)
            let graded = recipe.look.enabled
                ? try await frame(centerInput, recipe: recipe, library: library, gpu: gpu, preview: false)
                : try neutralFrame(centerInput, recipe: recipe)
            guard let transformed = GeometryRenderer.render(graded, geometry: recipe.geometry),
                  let center = transformed.cropping(to: recipe.crop.pixelRect(in: CGSize(width: transformed.width, height: transformed.height)))
            else { throw PhotoExporter.Failure.render }
            let paperPrint = !material.bypassesPrint && FilmStock.prints.first { $0.id == material.printID }?.support != "film"
            image = try FilmEdgeRenderer.replacingCenter(image, with: center, geometry: geometry, paperPrint: paperPrint)
        }
        try Task.checkCancellation()
        return try ToneRenderer.render(image, tone: original.tone.outputStage)
    }

    func export(
        _ recipe: EditRecipe, size: PhotoExporter.Size, format: PhotoExporter.Format,
        quality: Double,
        allowOvercommit: Bool = false
    )
        async throws -> (URL, Int, Int)
    {
        if exportKey != recipe || exportSize != size { exportImage = nil }
        let image: CGImage
        if let cached = exportImage {
            image = cached
        } else if recipe.filmEdgeLayout != nil {
            guard data != nil else { throw PhotoExporter.Failure.decode }
            releasePreviewCaches(keepMetering: true)
            let (_, gpu) = try await renderResources.load()
            await gpu.releaseWorkingCaches()
            do {
                let edged = try await renderFilmEdge(recipe, maximum: size.maximum, allowOvercommit: allowOvercommit)
                image = try recipe.printLayout.map { try PrintCompositor.render(edged, layout: $0, maximum: size.maximum) } ?? edged
            } catch {
                await gpu.releaseWorkingCaches()
                throw error
            }
            await gpu.releaseWorkingCaches()
        } else {
            releasePreviewCaches(keepMetering: true)
            guard let data else { throw PhotoExporter.Failure.decode }
            let dimensions = try PhotoExporter.sourceDimensions(data, sourceType: sourceType)
            let width = Int(dimensions.width)
            let height = Int(dimensions.height)
            let originalLong = max(width, height)
            let oriented =
                recipe.geometry.quarterTurns % 2 == 0
                ? CGSize(width: source.width, height: source.height)
                : CGSize(width: source.height, height: source.width)
            let crop = recipe.crop.pixelRect(in: oriented)
            let fraction = max(crop.width, crop.height) / max(oriented.width, oriented.height)
            let maximum = min(
                originalLong,
                size.maximum.map { Int(ceil(Double($0) / max(fraction, 1e-6))) } ?? originalLong
            )
            let scale = Double(maximum) / Double(originalLong)
            if recipe.look.enabled {
                let (_, exportGPU) = try await renderResources.load()
                await exportGPU.releaseWorkingCaches()
            }
            preview.filmImage = nil
            preview.opticsImage = nil
            preview.grainImages = nil
            try RenderMemoryBudget.check(
                width: max(1, Int(ceil(Double(width) * scale))),
                height: max(1, Int(ceil(Double(height) * scale))), recipe: recipe,
                allowOvercommit: allowOvercommit)
            // The RAW input path decodes directly to float; an 8-bit fallback decode is redundant.
            let decoded = source
            selectInputMode(recipe.inputMode)
            let input = try SourceImageRenderer.prepare(
                data: data, fallback: decoded, recipe: recipe, maximum: maximum,
                sourceType: sourceType, allowsStore: true)
            let graded: CGImage
            if recipe.look.enabled {
                let (library, gpu) = try await renderResources.load()
                do {
                    graded = try await frame(
                        input, recipe: recipe, library: library, gpu: gpu, preview: false)
                } catch {
                    await gpu.releaseWorkingCaches()
                    throw error
                }
                await gpu.releaseWorkingCaches()
            } else {
                graded = try neutralFrame(input, recipe: recipe)
            }
            try Task.checkCancellation()
            guard let transformed = GeometryRenderer.render(graded, geometry: recipe.geometry),
                let cropped = transformed.cropping(
                    to: recipe.crop.pixelRect(
                        in: CGSize(width: transformed.width, height: transformed.height)))
            else { throw PhotoExporter.Failure.render }
            if let layout = recipe.printLayout, !layout.isIdentity {
                image = try PrintCompositor.render(cropped, layout: layout, maximum: size.maximum)
            } else {
                image = try Self.resize(cropped, maximum: size.maximum)
            }
            exportImage = image
            exportKey = recipe
            exportSize = size
        }
        try Task.checkCancellation()
        let url = try PhotoExporter.write(
            image, format: format, quality: quality,
            sourceData: data, sourceType: sourceType, sourceFilename: sourceFilename)
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        // The encoded file owns the export now; do not retain a full-resolution float bitmap.
        discardExport()
        return (url, image.width, image.height)
    }
    func discardExport() {
        exportImage = nil
        exportKey = nil
        exportSize = nil
    }
    func releasePreviewCaches(keepMetering: Bool = false) {
        let next = PreviewState(maximum: previewMaximum)
        let nextEdge = PreviewState(maximum: 720)
        if keepMetering {
            next.meter = preview.meter
            next.meteredEV = preview.meteredEV
            nextEdge.meter = edgeMetering.meter
            nextEdge.meteredEV = edgeMetering.meteredEV
        }
        preview = next
        edgeMetering = nextEdge
        alternatePreview = nil
    }
    private static func resize(_ image: CGImage, maximum: Int?) throws -> CGImage {
        guard let maximum, max(image.width, image.height) > maximum else { return image }
        let scale = Double(maximum) / Double(max(image.width, image.height))
        let output = CIImage(cgImage: image).applyingFilter(
            "CILanczosScaleTransform",
            parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        let rect = CGRect(
            x: 0, y: 0, width: floor(Double(image.width) * scale),
            height: floor(Double(image.height) * scale)
        )
        guard
            let resized = CIContext(options: [.cacheIntermediates: false]).createCGImage(
                output, from: rect, format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        else { throw PhotoExporter.Failure.render }
        return resized
    }
}
