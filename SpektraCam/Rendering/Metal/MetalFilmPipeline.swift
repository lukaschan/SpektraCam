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
    func releaseWorkingCaches() { diffusion.clear() }

    func process(
        _ input: [SIMD4<Float>], width: Int, height: Int, pipeline: FilmPipeline,
        stochastic: Bool = true, seed: UInt64 = 0, autoExposureEV: Double? = nil
    ) async throws -> Frame {
        try await beginFrame()
        defer { endFrame() }
        let started = ProcessInfo.processInfo.systemUptime
        let frame = try await renderBuffer(
            input, width: width, height: height, pipeline: pipeline,
            stochastic: stochastic, seed: seed, autoExposureEV: autoExposureEV)
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
        seed: UInt64 = 0, autoExposureEV: Double, grainMean: Bool = false
    ) async throws -> CGImage {
        try await beginFrame()
        defer { endFrame() }
        let frame = try await renderBuffer(
            input, width: width, height: height, pipeline: pipeline,
            seed: seed, autoExposureEV: autoExposureEV, grainMean: grainMean)
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

    private func renderBuffer(
        _ input: [SIMD4<Float>], width: Int, height: Int, pipeline: FilmPipeline,
        stochastic: Bool = true,
        seed: UInt64 = 0, autoExposureEV: Double? = nil, opticsOnly: Bool = false,
        grainMean: Bool = false,
        grainDensityOnly: Bool = false
    ) async throws -> BufferFrame {
        let started = ProcessInfo.processInfo.systemUptime
        let count = width * height
        guard width > 0, height > 0, input.count == count, count <= Int(UInt32.max) else {
            throw Failure.invalidShape
        }
        try Task.checkCancellation()
        let pitch =
            pipeline.recipe.number("camera.film_format_mm") * 1000 / Double(max(width, height))
        guard pitch.isFinite, pitch > 0 else { throw Failure.invalidShape }
        let color = pipeline.color
        let recipe = pipeline.recipe
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
            autoEV = try color.autoExposureEV(
                input.map { RGB(Double($0.x), Double($0.y), Double($0.z)) }, width: width,
                height: height)
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
        let uniformBuffer = try buffer(uniforms)
        let source = try buffer(input)
        var shape = model.shape
        shape.x = UInt32(count)
        var flags = model.flags
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
        func mix(
            _ a: MTLBuffer, _ b: MTLBuffer, into output: MTLBuffer, aWeight: RGB, bWeight: RGB,
            divisor: RGB = RGB(repeating: 1)
        ) throws {
            let coefficients = try buffer([vector(aWeight), vector(bWeight), vector(divisor)])
            let e = try encoder("mix_images", [a, b, output, coefficients])
            var n = UInt32(count)
            e.setBytes(&n, length: 4, index: 4)
            dispatch(e, "mix_images")
        }
        func blur(_ input: MTLBuffer, _ scale: RGB, exponential: Bool = false) throws -> MTLBuffer {
            let output = try pool.take()
            try spatial.encode(
                input: input, output: output, width: width, height: height, scale: scale,
                exponential: exponential, scratch: scratch, command: command)
            return output
        }
        func diffuse(_ image: MTLBuffer, _ prefix: String) throws {
            let p = pipeline.diffusion(prefix)
            if p.active && p.strength > 0 && p.spatialScale > 0 {
                try diffusion.encode(
                    input: image, output: image, width: width, height: height, pixelSize: pitch,
                    parameters: p, command: command)
            }
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
            dispatch(e, "random_lognormal_image")
            return output
        }
        func finish(_ result: MTLBuffer, invalid: MTLBuffer)
            async throws
            -> BufferFrame
        {
            try Task.checkCancellation()
            let tail = command.rootCommandBuffer
            submitted = true
            do {
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
            let maximum = try allocate(4)
            guard let b = command.makeBlitCommandEncoder() else { throw Failure.allocation }
            b.fill(buffer: maximum, range: 0..<4, value: 0)
            b.endEncoding()
            var n = UInt32(count)
            let reduce = try encoder("image_maximum", [raw, maximum])
            reduce.setBytes(&n, length: 4, index: 2)
            dispatch(reduce, "image_maximum")
            let e = try encoder("boost_image", [raw, raw, maximum])
            var p = SIMD4<Float>(
                Float(pow(2, boost) - 1),
                Float(pow(28, 1 - recipe.number("film_render.halation.boost_range"))),
                Float(0.184 * pow(2, recipe.number("film_render.halation.protect_ev"))), 0)
            e.setBytes(&p, length: 16, index: 3)
            e.setBytes(&n, length: 4, index: 4)
            dispatch(e, "boost_image")
        }
        try diffuse(raw, "camera.diffusion_filter")
        let lens = recipe.number("camera.lens_blur_um")
        if lens > 0 {
            let next = try blur(raw, RGB(repeating: lens / pitch))
            pool.release(raw)
            raw = next
        }
        let halo = pipeline.halation
        func positive(_ v: RGB) -> Bool { v.x > 0 || v.y > 0 || v.z > 0 }
        func bounded(_ v: RGB) -> RGB { RGB(max(v.x, 1e-6), max(v.y, 1e-6), max(v.z, 1e-6)) }
        if halo.active {
            let sigma = halo.scatterCore * halo.scatterScale / pitch
            let tail = halo.scatterTail * halo.scatterScale / pitch
            if halo.scatterAmount > 0 && (positive(sigma) || positive(tail)) {
                let core = try blur(raw, bounded(sigma))
                let extended = try blur(raw, bounded(tail), exponential: true)
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
                let accumulated = try pool.take()
                for k in 1...halo.bounces {
                    let image = try blur(raw, bounded(sigmaHalo * sqrt(Double(k))))
                    if k == 1 {
                        try mix(
                            image, image, into: accumulated,
                            aWeight: RGB(repeating: weights[k - 1] / total),
                            bWeight: .zero)
                    } else {
                        try mix(
                            accumulated, image, into: accumulated, aWeight: RGB(repeating: 1),
                            bWeight: RGB(repeating: weights[k - 1] / total))
                    }
                    pool.release(image)
                }
                try mix(
                    raw, accumulated, into: raw, aWeight: RGB(repeating: 1), bWeight: amount,
                    divisor: halo.renormalize ? RGB(repeating: 1) + amount : RGB(repeating: 1))
                pool.release(accumulated)
            }
        }
        if opticsOnly {
            try diffuse(raw, "enlarger.diffusion_filter")
            let invalid = try allocate(4)
            guard let clear = command.makeBlitCommandEncoder() else { throw Failure.allocation }
            clear.fill(buffer: invalid, range: 0..<4, value: 0)
            clear.endEncoding()
            let encoder = try encoder("finish_linear_image", [raw, invalid])
            var n = UInt32(count)
            encoder.setBytes(&n, length: 4, index: 2)
            dispatch(encoder, "finish_linear_image")
            return try await finish(raw, invalid: invalid)
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
                let gaussian = try blur(inhibition, RGB(repeating: radius / pitch))
                let tail = try blur(
                    inhibition,
                    RGB(
                        repeating: recipe.number("film_render.dir_couplers.diffusion_tail_um")
                            / pitch),
                    exponential: true)
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
            var offset = SIMD2<UInt32>.zero
            e.setBytes(&s, length: 16, index: 6)
            if !grainMean {
                e.setBytes(&key, length: 8, index: 7)
                e.setBytes(&offset, length: 8, index: 8)
            }
            dispatch(e, grainKernel)
            if grain.sublayers && grain.dyeCloudBlur > 0 {
                for i in 0..<3 {
                    let od = maxima[i] / particles[i]
                    let sigma = RGB(sqrt(od.x), sqrt(od.y), sqrt(od.z)) * grain.dyeCloudBlur
                    let next = try blur(layerImages[i], sigma)
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
                    let next = try blur(field, RGB(repeating: grain.microstructure.x / pitch))
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
                let next = try blur(density, RGB(repeating: grain.blur))
                pool.release(density)
                density = next
            }
        }
        if grainDensityOnly {
            let invalid = try allocate(4)
            guard let clear = command.makeBlitCommandEncoder() else { throw Failure.allocation }
            clear.fill(buffer: invalid, range: 0..<4, value: 0)
            clear.endEncoding()
            let encoder = try encoder("finish_linear_image", [density, invalid])
            var n = UInt32(count)
            encoder.setBytes(&n, length: 4, index: 2)
            dispatch(encoder, "finish_linear_image")
            return try await finish(density, invalid: invalid)
        }
        // Both branches share decoding, exposure, halation, development and couplers.
        // Only the print/scan tail repeats when monochrome grain is enabled.
        func finishScan(_ input: MTLBuffer) throws -> MTLBuffer {
            var density = input
            if !recipe.bypassesPrint {
                let paper = try pool.take()
                try node("paper_exposure_image", density, paper)
                pool.release(density)
                density = paper
                try diffuse(density, "enlarger.diffusion_filter")
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
                        let next = try blur(field, RGB(repeating: radius))
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
            try node("compress_image_gamut", density, density)
            let scanBlur = recipe.number("scanner.lens_blur")
            if scanBlur > 0 {
                let next = try blur(density, RGB(repeating: scanBlur))
                pool.release(density)
                density = next
            }
            let sigma = recipe.number("scanner.unsharp_mask[0]")
            let amount = recipe.number("scanner.unsharp_mask[1]")
            if sigma > 0 && amount > 0 {
                let blurred = try blur(density, RGB(repeating: sigma))
                try mix(
                    density, blurred, into: density, aWeight: RGB(repeating: 1 + amount),
                    bWeight: RGB(repeating: -amount))
                pool.release(blurred)
            }
            return density
        }
        density = try finishScan(density)
        if let clean = cleanGrain { cleanGrain = try finishScan(clean) }
        let invalid = try allocate(4)
        guard let initialize = command.makeBlitCommandEncoder() else { throw Failure.allocation }
        initialize.fill(buffer: invalid, range: 0..<4, value: 0)
        initialize.endEncoding()
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
        return try await finish(density, invalid: invalid)
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
    init(device: MTLDevice, length: Int) {
        self.device = device
        self.length = length
    }
    func take() throws -> MTLBuffer {
        if let buffer = free.popLast() { return buffer }
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw MetalFilmPipeline.Failure.allocation
        }
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--check-export") {
                NSLog(
                    "EXPORT GPU allocated=%llu MB buffer=%d MB",
                    UInt64(device.currentAllocatedSize) / 1_048_576, length / 1_048_576)
            }
        #endif
        return buffer
    }
    func release(_ buffer: MTLBuffer) {
        precondition(!free.contains { $0 === buffer }, "Double release in film frame pool")
        free.append(buffer)
    }
}
