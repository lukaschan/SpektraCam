import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders

/// Photochemical GPU graph. Frame intermediates stay on the GPU; scratch is shared by blur nodes.
actor MetalFilmPipeline {
    typealias RGB = SIMD3<Double>
    struct Frame: Sendable { let pixels: [SIMD4<Float>], wallSeconds: Double, gpuSeconds: Double? }
    enum Failure: Error { case unavailable, allocation, invalidShape, command, nonfinite }
    private let device: MTLDevice, queue: MTLCommandQueue
    private let functions: [String: MTLComputePipelineState]
    private let spatial: SpatialMetalKernels
    private let diffusion: DiffusionMetalKernels
    private var modelKey: EditRecipe?
    private var modelResources: MetalModelResources?
    private var frameActive = false
    private var waitingFrames: [CheckedContinuation<Void, Never>] = []

    private func beginFrame() async throws {
        if frameActive {
            await withCheckedContinuation { waitingFrames.append($0) }
        } else {
            frameActive = true
        }
        do { try Task.checkCancellation() } catch { endFrame(); throw error }
    }
    private func endFrame() {
        if waitingFrames.isEmpty { frameActive = false }
        else { waitingFrames.removeFirst().resume() }
    }

    init(sources: [String]) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
        else {
            throw Failure.unavailable
        }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        let library = try device.makeLibrary(
            source: sources.joined(separator: "\n") + RawAdjustments.shader
                + RawAdjustments.bufferKernel
                + Self.lutKernels + Self.monochromeKernel, options: options)
        var functions = [String: MTLComputePipelineState]()
        for name in [
            "finish_linear_image", "grain_layers_mean_image", "raw_adjust_image",
            "camera_exposure_image",
            "film_development_image", "coupler_development_image",
            "paper_exposure_image", "paper_development_image", "scan_image_xyz",
            "compress_image_gamut",
            "encode_image_srgb", "mix_images", "image_maximum", "boost_image", "grain_layers_image",
            "random_lognormal_image", "finish_grain_image", "apply_glare_image",
            "encode_monochrome_grain",
            "film_edge_gate", "film_edge_transmission", "film_edge_density",
            "tile_downsample", "tile_sample_proxy", "proxy_crop",
        ] {
            guard let function = library.makeFunction(name: name) else { throw Failure.unavailable }
            functions[name] = try device.makeComputePipelineState(function: function)
        }
        self.device = device
        self.queue = queue
        self.functions = functions
        spatial = try .init(device: device, library: library)
        diffusion = try .init(device: device, library: library)
    }
    private struct BufferFrame {
        let image: MTLBuffer, wallSeconds: Double, gpuSeconds: Double?
    }
    func releaseWorkingCaches() {
        diffusion.clear()
        regionCache = nil
    }

    func process(
        _ input: [SIMD4<Float>], width: Int, height: Int, pipeline: FilmPipeline,
        stochastic: Bool = true, seed: UInt64 = 0, autoExposureEV: Double? = nil,
        edge: FilmEdgeGeometry? = nil
    ) async throws -> Frame {
        try await beginFrame()
        defer { endFrame() }
        let started = ProcessInfo.processInfo.systemUptime
        let frame = try await renderBuffer(
            input, width: width, height: height, pipeline: pipeline,
            stochastic: stochastic, seed: seed, autoExposureEV: autoExposureEV, edge: edge)
        let pixels = Array(
            UnsafeBufferPointer(
                start: frame.image.contents().assumingMemoryBound(to: SIMD4<Float>.self),
                count: width * height))
        return Frame(
            pixels: pixels, wallSeconds: ProcessInfo.processInfo.systemUptime - started,
            gpuSeconds: frame.gpuSeconds)
    }

    func processImage(
        _ input: [SIMD4<Float>], width: Int, height: Int, pipeline: FilmPipeline,
        seed: UInt64 = 0, autoExposureEV: Double, grainMean: Bool = false,
        edge: FilmEdgeGeometry? = nil
    ) async throws -> CGImage {
        try await beginFrame()
        defer { endFrame() }
        let frame = try await renderBuffer(
            input, width: width, height: height, pipeline: pipeline,
            seed: seed, autoExposureEV: autoExposureEV, grainMean: grainMean, edge: edge)
        let owned = frame.image
        let data = Data(
            bytesNoCopy: owned.contents(), count: width * height * 16,
            deallocator: .custom { [owned] _, _ in withExtendedLifetime(owned) {} })
        return try PhotoColorBridge.workingImage(data, width: width, height: height)
    }

    /// LUT grain uses density fluctuations without the carrier's print/scan colors.
    /// Matching blurred expectations remove deterministic edge blur from the noise field.
    func processGrainPair(
        _ input: [SIMD4<Float>], width: Int, height: Int, pipeline: FilmPipeline,
        autoExposureEV: Double
    ) async throws -> (CGImage, CGImage) {
        try await beginFrame()
        defer { endFrame() }
        let mean = try await renderBuffer(
            input, width: width, height: height, pipeline: pipeline,
            autoExposureEV: autoExposureEV, grainMean: true, grainDensityOnly: true)
        let noisy = try await renderBuffer(
            input, width: width, height: height, pipeline: pipeline,
            autoExposureEV: autoExposureEV, grainDensityOnly: true)
        func image(_ owned: MTLBuffer) throws -> CGImage {
            let data = Data(
                bytesNoCopy: owned.contents(), count: width * height * 16,
                deallocator: .custom { [owned] _, _ in withExtendedLifetime(owned) {} })
            return try PhotoColorBridge.workingImage(data, width: width, height: height, encoded: false)
        }
        return try (image(noisy.image), image(mean.image))
    }

    // Full-size counterparts. Pixels stay in file-backed storage and are rendered in tiles.
    /// Film result, sRGB-encoded with extended range. A byte store is the finished SDR image.
    func processImage(
        _ source: PixelStore, pipeline: FilmPipeline, seed: UInt64 = 0, autoExposureEV: Double,
        edge: FilmEdgeGeometry? = nil, format: PixelStore.Format = .float,
        tiling: Tiling = Tiling()
    ) async throws -> PixelStore {
        try await beginFrame()
        defer { endFrame() }
        return try await renderTiled(
            source, pipeline: pipeline, seed: seed, autoExposureEV: autoExposureEV, edge: edge,
            format: format, tiling: tiling)
    }
    /// Noisy and expected linear densities for LUT grain.
    func processGrainPair(
        _ source: PixelStore, pipeline: FilmPipeline, autoExposureEV: Double,
        tiling: Tiling = Tiling()
    ) async throws -> (PixelStore, PixelStore) {
        try await beginFrame()
        defer { endFrame() }
        let mean = try await renderTiled(
            source, pipeline: pipeline, autoExposureEV: autoExposureEV, grainMean: true,
            grainDensityOnly: true, format: .float, tiling: tiling)
        let noisy = try await renderTiled(
            source, pipeline: pipeline, autoExposureEV: autoExposureEV, grainDensityOnly: true,
            format: .float, tiling: tiling)
        return (noisy, mean)
    }
    /// Linear RGB after the optical kernels only.
    func processOptics(_ source: PixelStore, pipeline: FilmPipeline, tiling: Tiling = Tiling())
        async throws -> PixelStore
    {
        try await beginFrame()
        defer { endFrame() }
        return try await renderTiled(
            source, pipeline: pipeline, autoExposureEV: 0, opticsOnly: true, format: .float,
            tiling: tiling)
    }
    /// Check entry: the tiled graph on an in-memory image.
    func processTiled(
        _ input: [SIMD4<Float>], width: Int, height: Int, pipeline: FilmPipeline,
        stochastic: Bool = true, seed: UInt64 = 0, autoExposureEV: Double, tiling: Tiling
    ) async throws -> [SIMD4<Float>] {
        guard input.count == width * height else { throw Failure.invalidShape }
        try await beginFrame()
        defer { endFrame() }
        let source = try PixelStore(width: width, height: height, format: .float)
        input.withUnsafeBytes { source.base.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        let result = try await renderTiled(
            source, pipeline: pipeline, stochastic: stochastic, seed: seed,
            autoExposureEV: autoExposureEV, format: .float, tiling: tiling)
        return Array(
            UnsafeBufferPointer(
                start: result.base.assumingMemoryBound(to: SIMD4<Float>.self), count: input.count))
    }

    /// Reuse the verified optical kernels in linear RGB, without the film/print color transform.
    func processOptics(_ input: [SIMD4<Float>], width: Int, height: Int, pipeline: FilmPipeline)
        async throws
        -> CGImage
    {
        try await beginFrame()
        defer { endFrame() }
        let frame = try await renderBuffer(
            input, width: width, height: height, pipeline: pipeline,
            autoExposureEV: 0, opticsOnly: true)
        let owned = frame.image
        let data = Data(
            bytesNoCopy: owned.contents(), count: width * height * 16,
            deallocator: .custom { [owned] _, _ in withExtendedLifetime(owned) {} })
        return try PhotoColorBridge.workingImage(data, width: width, height: height, encoded: false)
    }

    /// Per-frame constants shared by a whole-frame render and by every tile of a tiled one.
    private struct Setup {
        let model: MetalModelResources, uniformBuffer: MTLBuffer, autoEV: Double, pitch: Double
    }
    private func makeSetup(
        pipeline: FilmPipeline, width: Int, height: Int, autoExposureEV: Double?,
        edge: FilmEdgeGeometry?, metering: (() throws -> Double)? = nil
    ) throws -> Setup {
        if let edge, edge.width != width || edge.height != height { throw Failure.invalidShape }
        let pitch = edge?.pixelPitchMicrometers
            ?? pipeline.recipe.number("camera.film_format_mm") * 1000 / Double(max(width, height))
        guard pitch.isFinite, pitch > 0 else { throw Failure.invalidShape }
        let color = pipeline.color
        let recipe = pipeline.recipe
        guard edge == nil || autoExposureEV != nil || !recipe.flag("camera.auto_exposure") else {
            throw Failure.invalidShape
        }
        let model: MetalModelResources
        if modelKey == color.recipe, let cached = modelResources {
            model = cached
        } else {
            model = try MetalModelResources(device: device, pipeline: color)
            modelKey = color.recipe
            modelResources = model
        }
        var uniforms = model.uniforms
        let autoEV: Double
        if let autoExposureEV {
            autoEV = autoExposureEV
        } else if recipe.flag("camera.auto_exposure") {
            guard let metering else { throw Failure.invalidShape }
            autoEV = try metering()
        } else {
            autoEV = 0
        }
        uniforms[0].y = Float(pow(2, autoEV))
        let reference = pipeline.reference
        uniforms.append(
            SIMD4(
                Float(reference.gain), Float(reference.offset), reference.active ? 1 : 0,
                Float(reference.filmingScale)))
        uniforms.append(SIMD4(Float(reference.printingScale), 0, 0, 0))
        return try Setup(model: model, uniformBuffer: buffer(uniforms), autoEV: autoEV, pitch: pitch)
    }
    private func submit(_ command: MPSCommandBuffer) async throws {
        let tail = command.rootCommandBuffer
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            tail.addCompletedHandler { done in
                if let error = done.error {
                    c.resume(throwing: error)
                } else if done.status != .completed {
                    c.resume(throwing: Failure.command)
                } else {
                    c.resume()
                }
            }
            command.commit()
        }
    }

    private func renderBuffer(
        _ input: [SIMD4<Float>], width: Int, height: Int, pipeline: FilmPipeline,
        stochastic: Bool = true,
        seed: UInt64 = 0, autoExposureEV: Double? = nil, opticsOnly: Bool = false,
        grainMean: Bool = false,
        grainDensityOnly: Bool = false, edge: FilmEdgeGeometry? = nil
    ) async throws -> BufferFrame {
        let started = ProcessInfo.processInfo.systemUptime
        let count = width * height
        guard width > 0, height > 0, input.count == count, count <= Int(UInt32.max) else {
            throw Failure.invalidShape
        }
        try Task.checkCancellation()
        let setup = try makeSetup(
            pipeline: pipeline, width: width, height: height, autoExposureEV: autoExposureEV,
            edge: edge
        ) {
            try pipeline.color.autoExposureEV(
                input.map { RGB(Double($0.x), Double($0.y), Double($0.z)) }, width: width,
                height: height)
        }
        let source = try buffer(input)
        guard let originalCommand = queue.makeCommandBuffer() else { throw Failure.allocation }
        let command = MPSCommandBuffer(commandBuffer: originalCommand)
        var submitted = false
        defer {
            if !submitted {
                diffusion.clear()
                let status = command.rootCommandBuffer.status
                if status == .notEnqueued || status == .enqueued { command.commit() }
            }
        }
        let pool = FilmFrameBuffers(device: device, length: source.length)
        let scratch = try spatial.scratch(length: source.length)
        let invalid = try allocate(4)
        invalid.contents().storeBytes(of: 0, as: UInt32.self)
        let result = try encodeGraph(
            source: source, width: width, height: height, pipeline: pipeline, setup: setup,
            stochastic: stochastic, seed: seed, opticsOnly: opticsOnly, grainMean: grainMean,
            grainDensityOnly: grainDensityOnly, edge: edge, command: command, pool: pool,
            scratch: scratch, invalid: invalid, tile: nil)
        try Task.checkCancellation()
        let tail = command.rootCommandBuffer
        submitted = true
        do {
            try await submit(command)
        } catch {
            diffusion.clear()
            throw error
        }
        try Task.checkCancellation()
        guard invalid.contents().load(as: UInt32.self) == 0 else { throw Failure.nonfinite }
        return BufferFrame(
            image: result,
            wallSeconds: ProcessInfo.processInfo.systemUptime - started,
            gpuSeconds: tail === originalCommand
                ? max(0, tail.gpuEndTime - tail.gpuStartTime) : nil)
    }

    // MARK: Tiled rendering

    /// Tunable geometry of a tiled render. Defaults suit a phone; checks inject small values.
    struct Tiling: Sendable {
        /// Largest tile edge, halo included.
        var tileEdge = 2048
        /// Transform edge for the part of a diffusion filter convolved inside a tile.
        var transform = 2048
        /// Long edge of the low-resolution proxy that carries wide kernels.
        var proxyLongEdge = 1024
        /// Proxy reduction factor; derived from `proxyLongEdge` when nil.
        var factor: Int? = nil
        /// Halo, in standard deviations, kept around a recursive Gaussian inside a tile.
        var haloSigmas = 5.0
        /// Narrowest Gaussian, in proxy pixels, that the proxy is trusted to carry.
        var proxySigmas = 4.0
        /// The same for faint, wide glows (halation bounces, coupler diffusion), which add a
        /// small fraction to the image and tolerate a coarser proxy.
        var glowSigmas = 3.0
        func resolvedFactor(width: Int, height: Int) -> Int {
            if let factor { return max(factor, 2) }
            var value = 2
            while (max(width, height) + value - 1) / value > proxyLongEdge { value *= 2 }
            return value
        }
        /// Tile edge that fits the memory currently available to the process.
        static func fitting(available: UInt64) -> Tiling {
            var tiling = Tiling()
            // About fourteen tile-sized float buffers are live at the widest point of the graph.
            if available < 1_800 * 1_048_576 { tiling.tileEdge = 1536 }
            if available < 1_000 * 1_048_576 {
                tiling.tileEdge = 1024
                tiling.transform = 1024
            }
            return tiling
        }
    }
    /// One Gaussian of a blur. Channels wider than the tile limit are taken from the proxy.
    fileprivate struct Component {
        let weight: Double, sigma: RGB
        /// 1 where the channel is filtered inside the tile, 0 where it comes from the proxy.
        let inTile: RGB
    }
    fileprivate enum Deferred {
        case maximum
        case blur([[Component]])
        case diffusion(DiffusionCore.Parameters, [(Double, RGB)])
    }
    /// A stage whose wide kernel needs the proxy of its own input before tiles can pass it.
    fileprivate final class Group {
        var input: MTLBuffer?
        var results: [MTLBuffer?] = []
        var sum: MTLBuffer?
        var ready = false
        init(input: MTLBuffer?) { self.input = input }
    }
    fileprivate final class Run {
        let imageWidth: Int, imageHeight: Int, factor: Int, proxyWidth: Int, proxyHeight: Int
        let tiling: Tiling
        let maximum: MTLBuffer
        var maximumReady = false
        var groups: [Int: Group] = [:]
        /// Capture: the whole image is rendered once at proxy resolution, and every stage
        /// records the proxy that a later region render at full resolution will sample.
        var capture = false
        /// The boost anchor came from the proxy, so finer pixels may exceed it.
        var estimatedMaximum = false
        var captured: [(Group, Deferred)] = []
        var proxyPool: FilmFrameBuffers?
        var workspace: DiffusionMetalKernels.Workspace?
        var nearKernels: [Int: DiffusionMetalKernels.PSF] = [:]
        init(width: Int, height: Int, tiling: Tiling, maximum: MTLBuffer) {
            imageWidth = width
            imageHeight = height
            self.tiling = tiling
            factor = tiling.resolvedFactor(width: width, height: height)
            proxyWidth = (width + factor - 1) / factor
            proxyHeight = (height + factor - 1) / factor
            self.maximum = maximum
        }
        /// Proxy buffers carry one leading column and row; see `tile_downsample`.
        var paddedWidth: Int { proxyWidth + 1 }
        var paddedHeight: Int { proxyHeight + 1 }
        /// Widest standard deviation filtered inside a tile; the proxy keeps at least four samples.
        func sigmaLimit(glow: Bool) -> Double {
            (glow ? min(tiling.glowSigmas, tiling.proxySigmas) : tiling.proxySigmas) * Double(factor)
        }
        func support(_ sigma: Double) -> Int {
            if sigma <= 0 { return 0 }
            return sigma < 3 ? Int(3 * sigma + 0.5) : Int(ceil(tiling.haloSigmas * sigma))
        }
    }
    /// What one tile learned while encoding: its halo and the stage that stopped it, if any.
    fileprivate final class TileState {
        var halo = 0
        var transformRadius = 0
        var pending: (id: Int, input: MTLBuffer?, work: Deferred)?
    }
    fileprivate struct Tile {
        let x: Int, y: Int, run: Run, probe: Bool, state: TileState
    }
    private struct Barrier: Error {}

    private func encodeMix(
        _ command: MPSCommandBuffer, _ a: MTLBuffer, _ b: MTLBuffer, into output: MTLBuffer,
        aWeight: RGB, bWeight: RGB, divisor: RGB = RGB(repeating: 1), count: Int
    ) throws {
        func vector(_ v: RGB) -> SIMD4<Float> { .init(Float(v.x), Float(v.y), Float(v.z), 0) }
        let coefficients = try buffer([vector(aWeight), vector(bWeight), vector(divisor)])
        guard let e = command.makeComputeCommandEncoder(), let function = functions["mix_images"]
        else { throw Failure.allocation }
        e.setComputePipelineState(function)
        for (i, b) in [a, b, output, coefficients].enumerated() {
            e.setBuffer(b, offset: 0, index: i)
        }
        var n = UInt32(count)
        e.setBytes(&n, length: 4, index: 4)
        e.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(128, function.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        e.endEncoding()
    }

    /// Render a full-size image in tiles. Peak memory depends on the tile, not on the image.
    /// Narrow kernels are filtered inside each tile with a halo; kernels wider than the halo
    /// are filtered on a proxy that is the exact area mean of the stage they act on.
    private func renderTiled(
        _ source: PixelStore, pipeline: FilmPipeline, stochastic: Bool = true, seed: UInt64 = 0,
        autoExposureEV: Double, opticsOnly: Bool = false, grainMean: Bool = false,
        grainDensityOnly: Bool = false, edge: FilmEdgeGeometry? = nil,
        format: PixelStore.Format, tiling: Tiling
    ) async throws -> PixelStore {
        let width = source.width, height = source.height
        guard source.format == .float, width * height <= Int(UInt32.max) else {
            throw Failure.invalidShape
        }
        try Task.checkCancellation()
        let setup = try makeSetup(
            pipeline: pipeline, width: width, height: height, autoExposureEV: autoExposureEV,
            edge: edge)
        let maximum = try allocate(4)
        maximum.contents().storeBytes(of: 0, as: UInt32.self)
        let run = Run(width: width, height: height, tiling: tiling, maximum: maximum)
        let proxyPool = FilmFrameBuffers(
            device: device, length: run.paddedWidth * run.paddedHeight * 16)
        defer { diffusion.clear() }
        return try await renderTiles(
            run: run, setup: setup, pipeline: pipeline, stochastic: stochastic, seed: seed,
            opticsOnly: opticsOnly, grainMean: grainMean, grainDensityOnly: grainDensityOnly,
            edge: edge, format: format, region: (0, 0, width, height), proxyPool: proxyPool
        ) { _, _, _, _ in (source, 0, 0) }
    }

    /// Tile passes over `region` of the run's image. `fetch` supplies source pixels covering
    /// the requested rectangle (the region plus this pass's halo) as a store and its origin.
    /// A run whose proxies are already prepared finishes in one pass.
    private func renderTiles(
        run: Run, setup: Setup, pipeline: FilmPipeline, stochastic: Bool, seed: UInt64,
        opticsOnly: Bool, grainMean: Bool, grainDensityOnly: Bool, edge: FilmEdgeGeometry?,
        format: PixelStore.Format, region: (x: Int, y: Int, w: Int, h: Int),
        proxyPool: FilmFrameBuffers?,
        fetch: (Int, Int, Int, Int) throws -> (store: PixelStore, x: Int, y: Int)
    ) async throws -> PixelStore {
        let width = run.imageWidth, height = run.imageHeight
        let tiling = run.tiling
        guard region.w > 0, region.h > 0, region.x >= 0, region.y >= 0,
            region.x + region.w <= width, region.y + region.h <= height
        else { throw Failure.invalidShape }
        let edgeLength = min(tiling.tileEdge, max(width, height))
        // The probe's window is tiny; working buffers are sized once the halo is known.
        var length = 64 * 64 * 16
        var pool = FilmFrameBuffers(device: device, length: length)
        var scratch = try spatial.scratch(length: length)
        let invalid = try allocate(4)
        invalid.contents().storeBytes(of: 0, as: UInt32.self)
        let destination = try PixelStore(width: region.w, height: region.h, format: format)
        var source: (store: PixelStore, x: Int, y: Int)?

        /// Encode and run one window. `payload` is the part of the image this tile owns.
        func runTile(
            x: Int, y: Int, w: Int, h: Int, payload: (x: Int, y: Int, w: Int, h: Int)?
        ) async throws -> TileState {
            try Task.checkCancellation()
            let state = TileState()
            let tile = Tile(x: x, y: y, run: run, probe: payload == nil, state: state)
            guard let raw = queue.makeCommandBuffer() else { throw Failure.allocation }
            let command = MPSCommandBuffer(commandBuffer: raw)
            var result: MTLBuffer?
            do {
                try autoreleasepool {
                    let input = try pool.take()
                    if payload != nil, let source {
                        source.store.read(
                            x: x - source.x, y: y - source.y, width: w, height: h,
                            into: input.contents())
                    } else {
                        // The probe only walks the graph; its pixels are never used.
                        memset(input.contents(), 0, w * h * 16)
                    }
                    do {
                        result = try encodeGraph(
                            source: input, width: w, height: h, pipeline: pipeline, setup: setup,
                            stochastic: stochastic, seed: seed, opticsOnly: opticsOnly,
                            grainMean: grainMean, grainDensityOnly: grainDensityOnly, edge: edge,
                            command: command, pool: pool, scratch: scratch, invalid: invalid,
                            tile: tile)
                    } catch is Barrier {
                        guard let payload, let pending = state.pending, let stage = pending.input,
                            let target = run.groups[pending.id]?.input
                        else { return }
                        // The proxy pixel is the mean of the stage's own full-resolution input.
                        try encodeDownsample(
                            command, stage: stage, stageWidth: w, into: target, run: run,
                            factor: run.factor,
                            payload: (payload.x - x, payload.y - y, payload.w, payload.h),
                            origin: (payload.x, payload.y))
                    }
                }
            } catch {
                let status = command.rootCommandBuffer.status
                if status == .notEnqueued || status == .enqueued { command.commit() }
                throw error
            }
            try await submit(command)
            if let result, let payload {
                destination.write(
                    x: payload.x - region.x, y: payload.y - region.y, width: payload.w,
                    height: payload.h,
                    from: UnsafeRawPointer(result.contents()).advanced(
                        by: ((payload.y - y) * w + payload.x - x) * 16),
                    sourceRowBytes: w * 16)
            }
            pool.reset()
            return state
        }

        while true {
            // A small window discovers, from the graph itself, how far this pass can go
            // and how much halo its in-tile kernels consume on the way.
            let probe = try await runTile(
                x: 0, y: 0, w: min(64, width), h: min(64, height), payload: nil)
            let halo = probe.halo
            var window = edgeLength
            if probe.transformRadius > 0 {
                window = min(window, tiling.transform - 2 * probe.transformRadius)
            }
            let step = (window - 2 * halo) / run.factor * run.factor
            guard step >= run.factor, step > 0 else { throw Failure.allocation }
            let needed =
                min(edgeLength, min(step, region.w) + 2 * halo)
                * min(edgeLength, min(step, region.h) + 2 * halo) * 16
            if needed > length {
                length = needed
                pool = FilmFrameBuffers(device: device, length: length)
                scratch = try spatial.scratch(length: length)
            }
            if let pending = probe.pending {
                // A prepared run has every proxy; only a whole-image render can build one.
                guard let proxyPool, region.w == width, region.h == height else {
                    throw Failure.invalidShape
                }
                if case .maximum = pending.work {
                } else {
                    run.groups[pending.id] = try Group(input: proxyPool.take())
                }
            }
            let x0 = max(0, region.x - halo), y0 = max(0, region.y - halo)
            let x1 = min(width, region.x + region.w + halo)
            let y1 = min(height, region.y + region.h + halo)
            if source == nil || source!.x > x0 || source!.y > y0
                || source!.x + source!.store.width < x1 || source!.y + source!.store.height < y1
            {
                source = try fetch(x0, y0, x1 - x0, y1 - y0)
            }
            for py in stride(from: region.y, to: region.y + region.h, by: step) {
                for px in stride(from: region.x, to: region.x + region.w, by: step) {
                    let pw = min(step, region.x + region.w - px)
                    let ph = min(step, region.y + region.h - py)
                    let x0 = max(0, px - halo), y0 = max(0, py - halo)
                    let x1 = min(width, px + pw + halo), y1 = min(height, py + ph + halo)
                    _ = try await runTile(
                        x: x0, y: y0, w: x1 - x0, h: y1 - y0, payload: (px, py, pw, ph))
                }
            }
            guard let pending = probe.pending, let proxyPool else { break }
            switch pending.work {
            case .maximum:
                run.maximumReady = true
            case .blur(let plans):
                try await resolveBlur(run.groups[pending.id]!, plans: plans, run: run, pool: proxyPool)
            case .diffusion(let parameters, let far):
                try await resolveDiffusion(
                    run.groups[pending.id]!, parameters: parameters, far: far, run: run,
                    pitch: setup.pitch, pool: proxyPool)
            }
        }
        try Task.checkCancellation()
        guard invalid.contents().load(as: UInt32.self) == 0 else { throw Failure.nonfinite }
        return destination
    }

    // MARK: Region rendering for the zoomed preview

    /// Identity of a prepared run: one edit at one zoom level.
    struct RegionKey: Equatable, Sendable {
        let recipe: EditRecipe, width: Int, height: Int, factor: Int, autoExposureEV: Double
        let seed: UInt64
    }
    private var regionCache: (key: RegionKey, run: Run, halo: Int)?

    /// Prepare region rendering of a `width` x `height` image for one edit. Returns the halo, in
    /// pixels, that source rectangles must include, or nil when `proxy` (the whole image at
    /// 1/`factor` scale, rows of ceil(width / factor)) is required and was not supplied.
    func prepareRegion(
        width: Int, height: Int, factor: Int, pipeline: FilmPipeline, seed: UInt64 = 0,
        autoExposureEV: Double, tiling: Tiling = Tiling(), proxy: [SIMD4<Float>]?
    ) async throws -> Int? {
        let key = RegionKey(
            recipe: pipeline.recipe, width: width, height: height, factor: factor,
            autoExposureEV: autoExposureEV, seed: seed)
        if let cached = regionCache, cached.key == key { return cached.halo }
        guard let proxy else { return nil }
        try await beginFrame()
        defer { endFrame() }
        regionCache = nil
        var tiling = tiling
        tiling.factor = factor
        let maximum = try allocate(4)
        maximum.contents().storeBytes(of: 0, as: UInt32.self)
        let run = Run(width: width, height: height, tiling: tiling, maximum: maximum)
        guard run.factor == factor, proxy.count == run.proxyWidth * run.proxyHeight else {
            throw Failure.invalidShape
        }
        let coarse = try makeSetup(
            pipeline: pipeline, width: run.proxyWidth, height: run.proxyHeight,
            autoExposureEV: autoExposureEV, edge: nil)
        let proxyPool = FilmFrameBuffers(
            device: device, length: run.paddedWidth * run.paddedHeight * 16)
        run.capture = true
        run.proxyPool = proxyPool
        run.estimatedMaximum = true
        let source = try buffer(proxy)
        let pool = FilmFrameBuffers(device: device, length: source.length)
        let scratch = try spatial.scratch(length: source.length)
        let invalid = try allocate(4)
        invalid.contents().storeBytes(of: 0, as: UInt32.self)
        guard let raw = queue.makeCommandBuffer() else { throw Failure.allocation }
        let command = MPSCommandBuffer(commandBuffer: raw)
        do {
            _ = try encodeGraph(
                source: source, width: run.proxyWidth, height: run.proxyHeight,
                pipeline: pipeline, setup: coarse, stochastic: true, seed: seed,
                opticsOnly: false, grainMean: false, grainDensityOnly: false, edge: nil,
                command: command, pool: pool, scratch: scratch, invalid: invalid,
                tile: Tile(x: 0, y: 0, run: run, probe: false, state: TileState()))
        } catch {
            let status = command.rootCommandBuffer.status
            if status == .notEnqueued || status == .enqueued { command.commit() }
            diffusion.clear()
            throw error
        }
        try await submit(command)
        diffusion.clear()
        run.capture = false
        for (group, work) in run.captured {
            switch work {
            case .maximum: break
            case .blur(let plans):
                try await resolveBlur(group, plans: plans, run: run, pool: proxyPool)
            case .diffusion(let parameters, let far):
                try await resolveDiffusion(
                    group, parameters: parameters, far: far, run: run,
                    pitch: coarse.pitch / Double(factor), pool: proxyPool)
            }
        }
        run.captured = []
        run.maximumReady = true
        // A one-pixel request reveals the halo the graph needs around any region.
        let detail = try makeSetup(
            pipeline: pipeline, width: width, height: height, autoExposureEV: autoExposureEV,
            edge: nil)
        var halo = 0
        _ = try await renderTiles(
            run: run, setup: detail, pipeline: pipeline, stochastic: true, seed: seed,
            opticsOnly: false, grainMean: false, grainDensityOnly: false, edge: nil,
            format: .float, region: (0, 0, 1, 1), proxyPool: nil
        ) { _, _, w, h in
            halo = max(w, h) - 1
            return (try PixelStore(width: w, height: h, format: .float), 0, 0)
        }
        regionCache = (key, run, halo)
        return halo
    }
    /// Render `region` of a prepared image. `source` holds scene-linear pixels whose top-left
    /// corner is at `origin`, covering the region plus the prepared halo (clipped to the image).
    func processRegion(
        _ source: PixelStore, origin: (x: Int, y: Int), region: (x: Int, y: Int, w: Int, h: Int),
        key: RegionKey, pipeline: FilmPipeline
    ) async throws -> PixelStore {
        try await beginFrame()
        defer { endFrame() }
        guard let cached = regionCache, cached.key == key else { throw Failure.invalidShape }
        let setup = try makeSetup(
            pipeline: pipeline, width: key.width, height: key.height,
            autoExposureEV: key.autoExposureEV, edge: nil)
        return try await renderTiles(
            run: cached.run, setup: setup, pipeline: pipeline, stochastic: true, seed: key.seed,
            opticsOnly: false, grainMean: false, grainDensityOnly: false, edge: nil,
            format: .float, region: region, proxyPool: nil
        ) { _, _, _, _ in (source, origin.x, origin.y) }
    }

    /// Area-mean `stage` into a padded proxy buffer; see `tile_downsample`.
    private func encodeDownsample(
        _ command: MPSCommandBuffer, stage: MTLBuffer, stageWidth: Int, into target: MTLBuffer,
        run: Run, factor f: Int, payload: (x: Int, y: Int, w: Int, h: Int),
        origin: (x: Int, y: Int)
    ) throws {
        guard let e = command.makeComputeCommandEncoder(),
            let function = functions["tile_downsample"]
        else { throw Failure.allocation }
        e.setComputePipelineState(function)
        e.setBuffer(stage, offset: 0, index: 0)
        e.setBuffer(target, offset: 0, index: 1)
        var a = SIMD4<UInt32>(
            UInt32(stageWidth), UInt32(run.paddedWidth), UInt32(run.paddedHeight), UInt32(f))
        var b = SIMD4<UInt32>(
            UInt32(payload.x), UInt32(payload.y), UInt32(payload.w), UInt32(payload.h))
        var c = SIMD4<UInt32>(UInt32(origin.x), UInt32(origin.y), 0, 0)
        e.setBytes(&a, length: 16, index: 2)
        e.setBytes(&b, length: 16, index: 3)
        e.setBytes(&c, length: 16, index: 4)
        e.dispatchThreads(
            MTLSize(width: (payload.w + f - 1) / f, height: (payload.h + f - 1) / f, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        e.endEncoding()
    }

    /// Filter the proxy with the wide Gaussians of one blur stage.
    private func resolveBlur(
        _ group: Group, plans: [[Component]], run: Run, pool: FilmFrameBuffers
    ) async throws {
        guard let input = group.input, let raw = queue.makeCommandBuffer() else {
            throw Failure.allocation
        }
        let command = MPSCommandBuffer(commandBuffer: raw)
        let count = run.paddedWidth * run.paddedHeight
        let scratch = try spatial.scratch(length: count * 16)
        let factor = Double(run.factor)
        do {
            let temporary = try pool.take()
            group.results = try plans.map { components in
                var total: MTLBuffer?
                for component in components where component.inTile != RGB(repeating: 1) {
                    var sigma = RGB.zero
                    for c in 0..<3 where component.inTile[c] == 0 {
                        // Match the width the full-resolution filter really applies. Block
                        // averaging and bilinear sampling already contribute about factor / 2.
                        let applied = SpatialCore.effectiveDeviation(component.sigma[c])
                        sigma[c] = SpatialCore.sigma(
                            forEffectiveDeviation: sqrt(
                                max(applied * applied - factor * factor / 4, factor * factor))
                                / factor)
                    }
                    try spatial.encode(
                        input: input, output: temporary, width: run.paddedWidth,
                        height: run.paddedHeight, scale: sigma, scratch: scratch, command: command)
                    let weight = (RGB(repeating: 1) - component.inTile) * component.weight
                    let target = try total ?? pool.take()
                    try encodeMix(
                        command, temporary, total ?? temporary, into: target, aWeight: weight,
                        bWeight: total == nil ? .zero : RGB(repeating: 1), count: count)
                    total = target
                }
                return total
            }
        } catch {
            command.commit()
            throw error
        }
        try await submit(command)
        pool.release(input)
        group.input = nil
        group.ready = true
    }

    /// Convolve the proxy with the far components of a diffusion filter.
    private func resolveDiffusion(
        _ group: Group, parameters: DiffusionCore.Parameters, far: [(Double, RGB)], run: Run,
        pitch: Double, pool: FilmFrameBuffers
    ) async throws {
        guard let input = group.input, let raw = queue.makeCommandBuffer() else {
            throw Failure.allocation
        }
        let command = MPSCommandBuffer(commandBuffer: raw)
        let factor = Double(run.factor)
        var released: MTLBuffer?
        do {
            let radius = try DiffusionCore.radius(
                width: run.proxyWidth, height: run.proxyHeight, pixelSize: pitch * factor,
                parameters: parameters)
            func power(_ value: Int) -> Int {
                var n = 1
                while n < value { n *= 2 }
                return n
            }
            let work = try diffusion.workspace(
                width: power(run.proxyWidth + 2 * radius), height: power(run.proxyHeight + 2 * radius))
            let components = far.map {
                SIMD4<Float>(Float($0.1.x), Float($0.1.y), Float($0.1.z), Float($0.0 / factor))
            }
            let kernel = try diffusion.makePSF(
                plan: work.plan, radius: radius, components: components, samples: 4,
                command: command)
            // The transform mirrors at the image border; it does not use the leading pad.
            let cropped = try pool.take()
            guard let crop = command.makeComputeCommandEncoder(),
                let function = functions["proxy_crop"]
            else { throw Failure.allocation }
            crop.setComputePipelineState(function)
            crop.setBuffer(input, offset: 0, index: 0)
            crop.setBuffer(cropped, offset: 0, index: 1)
            var shape = SIMD4<UInt32>(
                UInt32(run.paddedWidth), UInt32(run.proxyWidth), UInt32(run.proxyHeight), 0)
            crop.setBytes(&shape, length: 16, index: 2)
            crop.dispatchThreads(
                MTLSize(width: run.proxyWidth * run.proxyHeight, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: min(128, function.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
            crop.endEncoding()
            try diffusion.convolve(
                work, kernel: kernel, input: cropped, width: run.proxyWidth, height: run.proxyHeight,
                radius: radius, mirrorsAtEdge: true, command: command)
            let result = try pool.take()
            released = cropped
            try diffusion.extract(
                work, output: result, finite: cropped, width: run.proxyWidth,
                height: run.proxyHeight, radius: radius, command: command)
            group.results = [result]
            group.sum = kernel.normalization
        } catch {
            command.commit()
            throw error
        }
        try await submit(command)
        if let released { pool.release(released) }
        pool.release(input)
        group.input = nil
        group.ready = true
    }

    /// Encode the photochemical graph for one buffer: a whole frame, or one tile of a larger image.
    /// A tile throws `Barrier` at the first stage whose proxy has not been prepared yet.
    private func encodeGraph(
        source: MTLBuffer, width: Int, height: Int, pipeline: FilmPipeline, setup: Setup,
        stochastic: Bool, seed: UInt64, opticsOnly: Bool, grainMean: Bool,
        grainDensityOnly: Bool, edge: FilmEdgeGeometry?, command: MPSCommandBuffer,
        pool: FilmFrameBuffers, scratch: SpatialMetalKernels.Scratch, invalid: MTLBuffer,
        tile: Tile?
    ) throws -> MTLBuffer {
        let count = width * height
        let pitch = setup.pitch
        let color = pipeline.color
        let recipe = pipeline.recipe
        let model = setup.model
        let uniformBuffer = setup.uniformBuffer
        let autoEV = setup.autoEV
        let reference = pipeline.reference
        var shape = model.shape
        shape.x = UInt32(count)
        var flags = model.flags
        // Random streams and edge geometry are addressed in full-image coordinates.
        let capturing = tile?.run.capture == true
        var streamTile = SIMD4<UInt32>(
            UInt32(width), UInt32(capturing ? width : tile?.run.imageWidth ?? width),
            UInt32(tile?.x ?? 0), UInt32(tile?.y ?? 0))
        var edgeTile = SIMD4<UInt32>(
            UInt32(width), UInt32(height), UInt32(tile?.x ?? 0), UInt32(tile?.y ?? 0))
        func vector(_ v: RGB) -> SIMD4<Float> { .init(Float(v.x), Float(v.y), Float(v.z), 0) }
        func encoder(_ name: String, _ buffers: [MTLBuffer]) throws -> MTLComputeCommandEncoder {
            guard let e = command.makeComputeCommandEncoder(), let function = functions[name] else {
                throw Failure.allocation
            }
            e.setComputePipelineState(function)
            for (i, b) in buffers.enumerated() { e.setBuffer(b, offset: 0, index: i) }
            return e
        }
        func dispatch(_ e: MTLComputeCommandEncoder, _ name: String, _ requestedCount: Int? = nil) {
            let n = requestedCount ?? count
            e.dispatchThreads(
                MTLSize(width: n, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: min(128, functions[name]!.maxTotalThreadsPerThreadgroup), height: 1,
                    depth: 1))
            e.endEncoding()
        }
        func node(
            _ name: String, _ input: MTLBuffer, _ output: MTLBuffer, _ extras: [MTLBuffer] = []
        ) throws {
            try Task.checkCancellation()
            let e = try encoder(name, [input, output] + model.buffers + [uniformBuffer])
            e.setBytes(&shape, length: 16, index: 10)
            e.setBytes(&flags, length: 16, index: 11)
            for (i, b) in extras.enumerated() { e.setBuffer(b, offset: 0, index: 12 + i) }
            dispatch(e, name)
        }
        let edgeNeutral = color.exposure.raw(RGB(repeating: 0.184))
        let edgeValues = edge.map { $0.uniforms(light: $0.leakLight(neutral: edgeNeutral), fogLight: $0.fogLight(neutral: edgeNeutral)) } ?? []
        func edgeNode(_ name: String, _ image: MTLBuffer, clear: RGB = .zero,
                      mode: FilmEdgeGeometry.Transmission = []) throws {
            guard edge != nil else { return }
            let e = try encoder(name, [image])
            edgeValues.withUnsafeBytes { e.setBytes($0.baseAddress!, length: $0.count, index: 1) }
            var value = vector(clear)
            value.w = Float(mode.rawValue)
            e.setBytes(&value, length: 16, index: 2)
            e.setBytes(&edgeTile, length: 16, index: 3)
            dispatch(e, name)
        }
        func mix(
            _ a: MTLBuffer, _ b: MTLBuffer, into output: MTLBuffer, aWeight: RGB, bWeight: RGB,
            divisor: RGB = RGB(repeating: 1)
        ) throws {
            try encodeMix(
                command, a, b, into: output, aWeight: aWeight, bWeight: bWeight, divisor: divisor,
                count: count)
        }
        /// Bilinear sample of a proxy image at this tile's pixels.
        func sampleProxy(_ proxy: MTLBuffer, into output: MTLBuffer, add: Bool, padded: Bool)
            throws
        {
            guard let tile else { throw Failure.invalidShape }
            let run = tile.run
            let e = try encoder("tile_sample_proxy", [proxy, output])
            var a = edgeTile
            var b = SIMD4<UInt32>(
                UInt32(padded ? run.paddedWidth : run.proxyWidth), UInt32(run.proxyWidth),
                UInt32(run.proxyHeight), UInt32(run.factor))
            var c = SIMD2<UInt32>(padded ? 1 : 0, add ? 1 : 0)
            e.setBytes(&a, length: 16, index: 2)
            e.setBytes(&b, length: 16, index: 3)
            e.setBytes(&c, length: 8, index: 4)
            dispatch(e, "tile_sample_proxy")
        }
        typealias BlurSpec = (scale: RGB, exponential: Bool)
        func whole(_ input: MTLBuffer, _ spec: BlurSpec) throws -> MTLBuffer {
            let output = try pool.take()
            try spatial.encode(
                input: input, output: output, width: width, height: height, scale: spec.scale,
                exponential: spec.exponential, scratch: scratch, command: command)
            return output
        }
        /// Split one stage's blurs between the tile and the proxy. `site` identifies the stage
        /// across tiles and passes. Throws `Barrier` until the stage's proxy is ready.
        /// Decide, per Gaussian and channel, what stays in the tile. `scale` converts the
        /// spec's sigma to full-resolution pixels (it is the proxy factor while capturing).
        func split(_ specs: [BlurSpec], _ run: Run, glow: Bool, scale: Double = 1)
            -> (plans: [[Component]], needsProxy: Bool, radius: Int)
        {
            let limit = run.sigmaLimit(glow: glow)
            var needsProxy = false
            var radius = 0
            let plans: [[Component]] = specs.map { spec in
                let fit =
                    spec.exponential
                    ? [(0.1633, 0.5360), (0.6496, 1.5236), (0.1870, 2.7684)] : [(1.0, 1.0)]
                return fit.map { entry in
                    let sigma = spec.scale * entry.1 * scale
                    var inTile = RGB(repeating: 1)
                    for c in 0..<3 {
                        if sigma[c] > limit {
                            inTile[c] = 0
                            needsProxy = true
                        } else {
                            radius = max(radius, run.support(sigma[c]))
                        }
                    }
                    return Component(weight: entry.0, sigma: sigma, inTile: inTile)
                }
            }
            return (plans, needsProxy, radius)
        }
        func planned(
            _ site: Int, _ input: MTLBuffer, _ specs: [BlurSpec], _ tile: Tile, glow: Bool
        ) throws -> ([[Component]], Group?) {
            let run = tile.run
            let (plans, needsProxy, radius) = split(specs, run, glow: glow)
            tile.state.halo += radius
            let group = run.groups[site]
            if needsProxy && group?.ready != true {
                tile.state.pending = (site, input, .blur(plans))
                throw Barrier()
            }
            return (plans, group)
        }
        /// Capture: keep this stage's input as the proxy its wide Gaussians will filter.
        func record(_ site: Int, _ input: MTLBuffer, _ work: Deferred, _ run: Run) throws {
            guard let proxyPool = run.proxyPool else { throw Failure.invalidShape }
            let group = try Group(input: proxyPool.take())
            try encodeDownsample(
                command, stage: input, stageWidth: width, into: group.input!, run: run, factor: 1,
                payload: (0, 0, width, height), origin: (0, 0))
            run.groups[site] = group
            run.captured.append((group, work))
        }
        func captureBlur(_ site: Int, _ input: MTLBuffer, _ specs: [BlurSpec], _ run: Run, glow: Bool)
            throws
        {
            let (plans, needsProxy, _) = split(specs, run, glow: glow, scale: Double(run.factor))
            if needsProxy { try record(site, input, .blur(plans), run) }
        }
        func tiled(
            _ input: MTLBuffer, _ spec: BlurSpec, _ components: [Component], _ proxy: MTLBuffer?
        ) throws -> MTLBuffer {
            if components.allSatisfy({ $0.inTile == RGB(repeating: 1) }) {
                return try whole(input, spec)
            }
            let output = try pool.take()
            let temporary = try pool.take()
            var started = false
            for component in components where component.inTile != .zero {
                try spatial.encode(
                    input: input, output: temporary, width: width, height: height,
                    scale: component.sigma * component.inTile, scratch: scratch,
                    command: command)
                try mix(
                    temporary, started ? output : temporary, into: output,
                    aWeight: component.inTile * component.weight,
                    bWeight: started ? RGB(repeating: 1) : .zero)
                started = true
            }
            pool.release(temporary)
            guard let proxy else { throw Failure.invalidShape }
            try sampleProxy(proxy, into: output, add: started, padded: true)
            return output
        }
        func blurs(_ site: Int, _ input: MTLBuffer, _ specs: [BlurSpec], glow: Bool = false)
            throws -> [MTLBuffer]
        {
            guard let tile else { return try specs.map { try whole(input, $0) } }
            if tile.run.capture {
                try captureBlur(site, input, specs, tile.run, glow: glow)
                return try specs.map { try whole(input, $0) }
            }
            let (plans, group) = try planned(site, input, specs, tile, glow: glow)
            return try plans.enumerated().map { k, components in
                try tiled(input, specs[k], components, group?.results[k])
            }
        }
        /// Weighted sum of several blurs of one input, holding one blur at a time.
        func blurSum(_ site: Int, _ input: MTLBuffer, _ specs: [BlurSpec], weights: [Double])
            throws -> MTLBuffer
        {
            var plans: [[Component]]?
            var group: Group?
            if let tile, tile.run.capture {
                try captureBlur(site, input, specs, tile.run, glow: true)
            } else if let tile {
                (plans, group) = try planned(site, input, specs, tile, glow: true)
            }
            let accumulated = try pool.take()
            for k in specs.indices {
                let image = try plans.map { try tiled(input, specs[k], $0[k], group?.results[k]) }
                    ?? whole(input, specs[k])
                if k == 0 {
                    try mix(
                        image, image, into: accumulated, aWeight: RGB(repeating: weights[k]),
                        bWeight: .zero)
                } else {
                    try mix(
                        accumulated, image, into: accumulated, aWeight: RGB(repeating: 1),
                        bWeight: RGB(repeating: weights[k]))
                }
                pool.release(image)
            }
            return accumulated
        }
        func blur(_ site: Int, _ input: MTLBuffer, _ scale: RGB, exponential: Bool = false) throws
            -> MTLBuffer
        {
            try blurs(site, input, [(scale, exponential)])[0]
        }
        func diffuse(_ site: Int, _ image: MTLBuffer, _ prefix: String) throws {
            let p = pipeline.diffusion(prefix)
            guard p.active && p.strength > 0 && p.spatialScale > 0 else { return }
            guard let tile else {
                try diffusion.encode(
                    input: image, output: image, width: width, height: height, pixelSize: pitch,
                    parameters: p, command: command)
                return
            }
            let run = tile.run
            // While capturing, this buffer is the proxy; the plan is the full-resolution one.
            let fine = capturing ? pitch / Double(run.factor) : pitch
            let components = try DiffusionCore.components(pixelSize: fine, parameters: p)
            let reference = try DiffusionCore.radius(
                width: run.imageWidth, height: run.imageHeight, pixelSize: fine, parameters: p)
            // Exponential components up to two proxy pixels wide keep their cusp inside the tile.
            var near = components
            var far = [(Double, RGB)]()
            if reference > 16 * run.factor {
                near = components.filter { $0.0 <= 2 * Double(run.factor) }
                far = components.filter { $0.0 > 2 * Double(run.factor) }
            }
            if capturing {
                if !far.isEmpty { try record(site, image, .diffusion(p, far), run) }
                try diffusion.encode(
                    input: image, output: image, width: width, height: height, pixelSize: pitch,
                    parameters: p, command: command)
                return
            }
            let radius =
                near.isEmpty
                ? 0 : min(reference, max(Int(ceil(8 * near.map(\.0).max()!)), 5))
            tile.state.halo += radius
            tile.state.transformRadius = max(tile.state.transformRadius, radius)
            let group = run.groups[site]
            if !far.isEmpty && group?.ready != true {
                tile.state.pending = (site, image, .diffusion(p, far))
                throw Barrier()
            }
            if tile.probe { return }
            var work: DiffusionMetalKernels.Workspace?
            var kernel: DiffusionMetalKernels.PSF?
            if !near.isEmpty {
                let side = run.tiling.transform
                guard width + 2 * radius <= side, height + 2 * radius <= side else {
                    throw Failure.invalidShape
                }
                if run.workspace == nil {
                    run.workspace = try diffusion.workspace(width: side, height: side)
                }
                work = run.workspace
                if run.nearKernels[site] == nil {
                    run.nearKernels[site] = try diffusion.makePSF(
                        plan: work!.plan, radius: radius,
                        components: near.map {
                            SIMD4<Float>(Float($0.1.x), Float($0.1.y), Float($0.1.z), Float($0.0))
                        }, command: command)
                }
                kernel = run.nearKernels[site]
                try diffusion.convolve(
                    work!, kernel: kernel!, input: image, width: width, height: height,
                    radius: radius, command: command)
            }
            var farTile: MTLBuffer?
            if !far.isEmpty, let proxy = group?.results.first ?? nil {
                farTile = try pool.take()
                try sampleProxy(proxy, into: farTile!, add: false, padded: false)
            }
            try diffusion.finishTile(
                work, near: kernel, far: farTile, farSum: group?.sum, farGain: 1, original: image,
                output: image, width: width, height: height, radius: radius,
                fraction: Float(try DiffusionCore.scatter(strength: p.strength, family: p.family)),
                command: command)
            if let farTile { pool.release(farTile) }
        }
        func randomField(mean: Double, standardDeviation: Double, domain: UInt32, independent: Bool)
            throws
            -> MTLBuffer
        {
            let output = try pool.take()
            let e = try encoder("random_lognormal_image", [output])
            var parameters = SIMD2<Float>(Float(mean), Float(standardDeviation))
            var s = SIMD4<UInt32>(UInt32(count), domain, 0, 0)
            var key = SIMD2<UInt32>(
                UInt32(truncatingIfNeeded: seed), UInt32(truncatingIfNeeded: seed >> 32))
            var channels: UInt32 = independent ? 1 : 0
            e.setBytes(&parameters, length: 8, index: 1)
            e.setBytes(&s, length: 16, index: 2)
            e.setBytes(&key, length: 8, index: 3)
            e.setBytes(&channels, length: 4, index: 4)
            e.setBytes(&streamTile, length: 16, index: 5)
            dispatch(e, "random_lognormal_image")
            return output
        }
        func finishLinear(_ image: MTLBuffer) throws {
            let encoder = try encoder("finish_linear_image", [image, invalid])
            var n = UInt32(count)
            encoder.setBytes(&n, length: 4, index: 2)
            dispatch(encoder, "finish_linear_image")
        }
        // App RAW controls run before optical diffusion, emulsion exposure and development.
        if !recipe.tone.rawStage.isIdentity {
            let values = RawAdjustments.parameters(
                recipe.tone.rawStage,
                normalizationEV: recipe.look.mode == .spektrafilm && !opticsOnly ? autoEV : 0)
            let e = try encoder("raw_adjust_image", [source])
            values.withUnsafeBytes { e.setBytes($0.baseAddress!, length: $0.count, index: 1) }
            var n = UInt32(count)
            e.setBytes(&n, length: 4, index: 2)
            dispatch(e, "raw_adjust_image")
        }
        var raw: MTLBuffer
        if opticsOnly {
            raw = source
        } else {
            raw = try pool.take()
            try node("camera_exposure_image", source, raw)
            pool.release(source)
        }
        let boost = recipe.number("film_render.halation.boost_ev")
        if boost > 0 {
            var n = UInt32(count)
            func reduce(into maximum: MTLBuffer) throws {
                let reduce = try encoder("image_maximum", [raw, maximum])
                reduce.setBytes(&n, length: 4, index: 2)
                dispatch(reduce, "image_maximum")
            }
            let maximum: MTLBuffer
            if let tile {
                // The boost curve is anchored to the brightest value of the whole image.
                maximum = tile.run.maximum
                if capturing {
                    try reduce(into: maximum)
                } else if !tile.run.maximumReady {
                    if !tile.probe { try reduce(into: maximum) }
                    tile.state.pending = (-1, nil, .maximum)
                    throw Barrier()
                }
            } else {
                maximum = try allocate(4)
                guard let b = command.makeBlitCommandEncoder() else { throw Failure.allocation }
                b.fill(buffer: maximum, range: 0..<4, value: 0)
                b.endEncoding()
                try reduce(into: maximum)
            }
            let e = try encoder("boost_image", [raw, raw, maximum])
            var p = SIMD4<Float>(
                Float(pow(2, boost) - 1),
                Float(pow(28, 1 - recipe.number("film_render.halation.boost_range"))),
                Float(0.184 * pow(2, recipe.number("film_render.halation.protect_ev"))),
                tile?.run.estimatedMaximum == true ? 1 : 0)
            e.setBytes(&p, length: 16, index: 3)
            e.setBytes(&n, length: 4, index: 4)
            dispatch(e, "boost_image")
        }
        try diffuse(1, raw, "camera.diffusion_filter")
        let lens = recipe.number("camera.lens_blur_um")
        if lens > 0 {
            let next = try blur(2, raw, RGB(repeating: lens / pitch))
            pool.release(raw)
            raw = next
        }
        // The camera gate follows lens optics; halation can then expose intact rebate.
        try edgeNode("film_edge_gate", raw)
        let halo = pipeline.halation
        func positive(_ v: RGB) -> Bool { v.x > 0 || v.y > 0 || v.z > 0 }
        func bounded(_ v: RGB) -> RGB { RGB(max(v.x, 1e-6), max(v.y, 1e-6), max(v.z, 1e-6)) }
        if halo.active {
            let sigma = halo.scatterCore * halo.scatterScale / pitch
            let tail = halo.scatterTail * halo.scatterScale / pitch
            if halo.scatterAmount > 0 && (positive(sigma) || positive(tail)) {
                let scattered = try blurs(3, raw, [(bounded(sigma), false), (bounded(tail), true)])
                let core = scattered[0], extended = scattered[1]
                let combined = try pool.take()
                try mix(
                    core, extended, into: combined, aWeight: RGB(repeating: 1) - halo.tailWeight,
                    bWeight: halo.tailWeight)
                try mix(
                    raw, combined, into: combined, aWeight: RGB(repeating: 1 - halo.scatterAmount),
                    bWeight: RGB(repeating: halo.scatterAmount))
                pool.release(core)
                pool.release(extended)
                pool.release(raw)
                raw = combined
            }
            let amount = halo.strength * halo.amount
            let sigmaHalo = halo.firstSigma * halo.scale / pitch
            if halo.bounces >= 1 && positive(amount) && positive(sigmaHalo) {
                let weights = (0..<halo.bounces).map { pow(halo.decay, Double($0)) }
                let total = weights.reduce(0, +)
                // Every bounce filters the same input, so one proxy serves them all.
                let accumulated = try blurSum(
                    4, raw, (1...halo.bounces).map { (bounded(sigmaHalo * sqrt(Double($0))), false) },
                    weights: weights.map { $0 / total })
                try mix(
                    raw, accumulated, into: raw, aWeight: RGB(repeating: 1), bWeight: amount,
                    divisor: halo.renormalize ? RGB(repeating: 1) + amount : RGB(repeating: 1))
                pool.release(accumulated)
            }
        }
        if opticsOnly {
            try diffuse(15, raw, "enlarger.diffusion_filter")
            try finishLinear(raw)
            return raw
        }
        let logRaw = try pool.take()
        let inhibition = try pool.take()
        var density = try pool.take()
        try node("film_development_image", raw, density, [logRaw, inhibition])
        pool.release(raw)
        if color.coupledDevelopment != nil {
            var correction = inhibition
            let radius = recipe.number("film_render.dir_couplers.diffusion_size_um")
            if radius > 0 {
                let spread = try blurs(
                    5, inhibition,
                    [
                        (RGB(repeating: radius / pitch), false),
                        (
                            RGB(
                                repeating: recipe.number("film_render.dir_couplers.diffusion_tail_um")
                                    / pitch), true
                        ),
                    ], glow: true)
                let gaussian = spread[0], tail = spread[1]
                let weight = recipe.number("film_render.dir_couplers.diffusion_tail_weight")
                try mix(
                    gaussian, tail, into: inhibition, aWeight: RGB(repeating: 1 - weight),
                    bWeight: RGB(repeating: weight))
                pool.release(gaussian)
                pool.release(tail)
                correction = inhibition
            }
            try node("coupler_development_image", correction, density, [logRaw])
        }
        pool.release(logRaw)
        pool.release(inhibition)
        let grain = pipeline.grain
        var cleanGrain: MTLBuffer?
        if stochastic && grain.active && recipe.monochromeGrain {
            let clean = try pool.take()
            try mix(density, density, into: clean, aWeight: RGB(repeating: 1), bWeight: .zero)
            cleanGrain = clean
        }
        if stochastic && grain.active {
            guard grain.simpleSublayers >= 1, grain.simpleSublayers <= 100 else {
                throw Failure.invalidShape
            }
            let layerCount = grain.sublayers ? 3 : 1
            var layerImages = try (0..<layerCount).map { _ in try pool.take() }
            var maxima = Array(repeating: RGB.zero, count: 3)
            var particles = maxima
            var minima = maxima
            var layerCurves = [SIMD4<Float>]()
            let curveCount: Int
            if grain.sublayers {
                let layers = try GrainCore.Layers(
                    curves: color.filmCurve.values,
                    layers: pipeline.film.densityLayers.map { $0.map(ModelLibrary.vector) },
                    positive: pipeline.film.positive)
                let total = layers.maximum.reduce(RGB.zero, +)
                minima = layers.maximum.map { $0 / total * grain.minimum }
                maxima = (0..<3).map { layers.maximum[$0] + minima[$0] }
                particles = try layers.particlesPerPixel(
                    pixelSize: pitch, area: grain.area, scale: grain.scale,
                    layerScale: grain.layerScale)
                curveCount = layers.interpolation[0].axis.count
                for curve in layers.interpolation {
                    for i in curve.axis.indices {
                        var v = vector(curve.values[i])
                        v.w = Float(curve.axis[i])
                        layerCurves.append(v)
                    }
                }
            } else {
                maxima[0] =
                    color.filmCurve.values.reduce(RGB(repeating: -.infinity)) {
                        RGB(max($0.x, $1.x), max($0.y, $1.y), max($0.z, $1.z))
                    } + grain.minimum
                particles[0] = RGB(repeating: pitch * pitch) / (grain.area * grain.scale)
                minima[0] = grain.minimum
                curveCount = 1
                layerCurves = [.zero]
            }
            let configuration = try buffer(
                (maxima + particles + minima + [grain.uniformity]).map(vector))
            let curves = try buffer(layerCurves)
            let grainKernel = grainMean ? "grain_layers_mean_image" : "grain_layers_image"
            let e = try encoder(
                grainKernel,
                [
                    density, layerImages[0], layerImages.last!, layerImages.last!, curves,
                    configuration,
                ])
            if layerCount == 3 { e.setBuffer(layerImages[1], offset: 0, index: 2) }
            var s = SIMD4<UInt32>(
                UInt32(count), UInt32(curveCount), grain.sublayers ? 1 : 0,
                UInt32(grain.simpleSublayers) << 1 | (pipeline.film.positive ? 1 : 0))
            var key = SIMD2<UInt32>(
                UInt32(truncatingIfNeeded: seed), UInt32(truncatingIfNeeded: seed >> 32))
            e.setBytes(&s, length: 16, index: 6)
            if !grainMean {
                e.setBytes(&key, length: 8, index: 7)
                e.setBytes(&streamTile, length: 16, index: 8)
            }
            dispatch(e, grainKernel)
            if grain.sublayers && grain.dyeCloudBlur > 0 {
                for i in 0..<3 {
                    let od = maxima[i] / particles[i]
                    let sigma = RGB(sqrt(od.x), sqrt(od.y), sqrt(od.z)) * grain.dyeCloudBlur
                    let next = try blur(6 + i, layerImages[i], sigma)
                    pool.release(layerImages[i])
                    layerImages[i] = next
                }
            }
            var micro: MTLBuffer?
            let microSigma = grain.microstructure.y * 0.001 / pitch
            if grain.sublayers && microSigma > 0.05 && !grainMean {
                var field = try randomField(
                    mean: 1, standardDeviation: microSigma, domain: 512, independent: true)
                if grain.microstructure.x / pitch > 0.4 {
                    let next = try blur(9, field, RGB(repeating: grain.microstructure.x / pitch))
                    pool.release(field)
                    field = next
                }
                micro = field
            }
            let finish = try encoder(
                "finish_grain_image",
                [
                    layerImages[0], layerImages.count == 3 ? layerImages[1] : layerImages[0],
                    layerImages.last!, micro ?? layerImages[0], density,
                ])
            var minimum = vector(grain.minimum)
            var grainShape = SIMD4<UInt32>(
                UInt32(count), UInt32(layerCount), micro == nil ? 0 : 1, 0)
            finish.setBytes(&minimum, length: 16, index: 5)
            finish.setBytes(&grainShape, length: 16, index: 6)
            dispatch(finish, "finish_grain_image")
            for image in layerImages { pool.release(image) }
            if let micro { pool.release(micro) }
            if grain.blur > (grain.sublayers ? 0 : 0.4) {
                let next = try blur(10, density, RGB(repeating: grain.blur))
                pool.release(density)
                density = next
            }
        }
        if grainDensityOnly {
            try finishLinear(density)
            return density
        }
        // Both branches share decoding, exposure, halation, development and couplers.
        // Only the print/scan tail repeats when monochrome grain is enabled.
        func finishScan(_ input: MTLBuffer, branch: Int) throws -> MTLBuffer {
            var density = input
            if edge?.hasEmulsionScratches == true { try edgeNode("film_edge_density", density) }
            if !recipe.bypassesPrint {
                let paper = try pool.take()
                try node("paper_exposure_image", density, paper)
                if let enlarger = color.enlarger {
                    let cinema = FilmStock.prints.first { $0.id == recipe.printID }?.support == "film"
                    try edgeNode("film_edge_transmission", paper,
                                 clear: enlarger.clearExposure * reference.printingScale,
                                 mode: cinema ? [.damage] : [.damage, .carrier, .reflection])
                }
                pool.release(density)
                density = paper
                try diffuse(branch + 11, density, "enlarger.diffusion_filter")
                try node("paper_development_image", density, density)
            }
            try node("scan_image_xyz", density, density)
            if stochastic && !recipe.bypassesPrint && recipe.flag("print_render.glare.active") {
                let mean = recipe.number("print_render.glare.percent")
                if mean > 0 {
                    var field = try randomField(
                        mean: mean,
                        standardDeviation: mean * recipe.number("print_render.glare.roughness"),
                        domain: 1024, independent: false)
                    let radius = recipe.number("print_render.glare.blur")
                    if radius > 0 {
                        let next = try blur(branch + 12, field, RGB(repeating: radius))
                        pool.release(field)
                        field = next
                    }
                    let scan = color.scanBasis
                    let white =
                        zip(scan.illuminant, scan.cmfs).reduce(RGB.zero) { $0 + $1.0 * $1.1 }
                        / scan.normalization
                    let e = try encoder("apply_glare_image", [density, field])
                    var w = vector(white)
                    var n = UInt32(count)
                    e.setBytes(&w, length: 16, index: 2)
                    e.setBytes(&n, length: 4, index: 3)
                    dispatch(e, "apply_glare_image")
                    pool.release(field)
                }
            }
            let destinationFilm = !recipe.bypassesPrint
                && FilmStock.prints.first { $0.id == recipe.printID }?.support == "film"
            if recipe.bypassesPrint || destinationFilm {
                let scan = color.scanBasis
                let clear = reference.correct(zip(scan.illuminant, scan.cmfs).reduce(RGB.zero) { $0 + $1.0 * $1.1 } / scan.normalization)
                // Destination holes are openings, distinct from the printed source-hole image.
                try edgeNode("film_edge_transmission", density, clear: clear,
                             mode: destinationFilm ? [.carrier, .destination] : [.damage, .carrier])
            }
            try node("compress_image_gamut", density, density)
            let scanBlur = recipe.number("scanner.lens_blur")
            if scanBlur > 0 {
                let next = try blur(branch + 13, density, RGB(repeating: scanBlur))
                pool.release(density)
                density = next
            }
            let sigma = recipe.number("scanner.unsharp_mask[0]")
            let amount = recipe.number("scanner.unsharp_mask[1]")
            if sigma > 0 && amount > 0 {
                let blurred = try blur(branch + 14, density, RGB(repeating: sigma))
                try mix(
                    density, blurred, into: density, aWeight: RGB(repeating: 1 + amount),
                    bWeight: RGB(repeating: -amount))
                pool.release(blurred)
            }
            if !recipe.bypassesPrint && !destinationFilm {
                // Clear source openings define the finished negative-print black endpoint.
                // Apply in linear light, after scan optics; intact rebate color is retained.
                try edgeNode("film_edge_transmission", density, mode: [.endpoint, .carrier])
            }
            return density
        }
        density = try finishScan(density, branch: 0)
        if let clean = cleanGrain { cleanGrain = try finishScan(clean, branch: 20) }
        if let clean = cleanGrain {
            let e = try encoder(
                "encode_monochrome_grain", [density, clean, uniformBuffer, invalid])
            var n = UInt32(count)
            e.setBytes(&n, length: 4, index: 4)
            dispatch(e, "encode_monochrome_grain")
            pool.release(clean)
        } else {
            try node("encode_image_srgb", density, density, [invalid])
        }
        return density
    }

    /// The expectation uses the same sublayers, particle bounds and blur as the noisy density.
    private static let lutKernels = """
        kernel void finish_linear_image(device float4 *pixels [[buffer(0)]],
            device atomic_uint *invalid [[buffer(1)]], constant uint &count [[buffer(2)]],
            uint i [[thread_position_in_grid]]) {
            if(i>=count)return;
            if(!all(isfinite(pixels[i].rgb)))atomic_store_explicit(invalid,1u,memory_order_relaxed);
            pixels[i].w=1;
        }
        kernel void grain_layers_mean_image(device const float4 *density [[buffer(0)]],
            device float4 *first [[buffer(1)]], device float4 *second [[buffer(2)]], device float4 *third [[buffer(3)]],
            device const float4 *curves [[buffer(4)]], constant float4 *p [[buffer(5)]],
            constant uint4 &shape [[buffer(6)]], uint i [[thread_position_in_grid]]) {
            if(i>=shape.x)return;
            bool layers=shape.z!=0, positive=(shape.w&1)!=0;
            float3 split[3];
            if(layers)for(uint ch=0;ch<3;++ch) {
                float value=density[i][ch]*(positive?-1.0f:1.0f);
                float3 layer=lookup_curve(float3(value),curves+ch*shape.y,shape.y);
                split[0][ch]=layer.x;split[1][ch]=layer.y;split[2][ch]=layer.z;
            }
            for(uint layer=0;layer<(layers?3:1);++layer) {
                float3 value=layers?split[layer]+p[6+layer].xyz:density[i].xyz+p[6].xyz;
                float3 expected=p[layer].xyz*clamp(value/p[layer].xyz,1e-6f,1-1e-6f);
                if(layer==0)first[i]=float4(expected,0);
                else if(layer==1)second[i]=float4(expected,0);
                else third[i]=float4(expected,0);
            }
        }
        """

    private static let monochromeKernel = """

        kernel void encode_monochrome_grain(device float4 *grain [[buffer(0)]],
            device const float4 *clean [[buffer(1)]], constant float4 *p [[buffer(2)]],
            device atomic_uint *invalid [[buffer(3)]], constant uint& count [[buffer(4)]],
            uint i [[thread_position_in_grid]]) {
            if(i >= count) return;
            float3 baseline = apply_basis(p, 13, clean[i].xyz);
            float3 noisy = apply_basis(p, 13, grain[i].xyz);
            float residual = dot(noisy - baseline, float3(0.2126f, 0.7152f, 0.0722f));
            float3 rgb = baseline + residual;
            float3 encoded = float3(encode_srgb(rgb.x), encode_srgb(rgb.y), encode_srgb(rgb.z));
            if(!all(isfinite(encoded))) atomic_store_explicit(invalid, 1u, memory_order_relaxed);
            grain[i] = float4(encoded, 1);
        }
        """

    private func allocate(_ length: Int) throws -> MTLBuffer {
        guard length <= device.maxBufferLength,
            let result = device.makeBuffer(length: length, options: .storageModeShared)
        else { throw Failure.allocation }
        return result
    }
    private func buffer<T>(_ values: [T]) throws -> MTLBuffer {
        guard
            let result = values.withUnsafeBytes({
                device.makeBuffer(
                    bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            })
        else { throw Failure.allocation }
        return result
    }
}

/// Reuse only after a node's last read has been encoded. Tracked-resource encoder order
/// preserves dependencies even when MPS splits the command buffer; each frame owns its pool.
private nonisolated final class FilmFrameBuffers {
    private let device: MTLDevice, length: Int
    private var free = [MTLBuffer]()
    private var all = [MTLBuffer]()
    init(device: MTLDevice, length: Int) {
        self.device = device
        self.length = length
    }
    func take() throws -> MTLBuffer {
        if let buffer = free.popLast() { return buffer }
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw MetalFilmPipeline.Failure.allocation
        }
        all.append(buffer)
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--check-export") {
                NSLog(
                    "EXPORT GPU allocated=%llu MB buffer=%d MB",
                    UInt64(device.currentAllocatedSize) / 1_048_576, length / 1_048_576)
            }
        #endif
        return buffer
    }
    /// Return every buffer after a tile's commands have completed.
    func reset() { free = all }
    func release(_ buffer: MTLBuffer) {
        precondition(!free.contains { $0 === buffer }, "Double release in film frame pool")
        free.append(buffer)
    }
}
