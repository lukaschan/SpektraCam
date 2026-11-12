import Foundation
import Metal
import MetalPerformanceShaders
import MetalPerformanceShadersGraph

/// Test worker using the same GPU PSF/FFT encoders as the combined image graph.
actor MetalDiffusion {
    enum Failure: Error { case unavailable, allocation, command }
    private let device: MTLDevice, queue: MTLCommandQueue
    private let kernels: DiffusionMetalKernels
    init(source: String) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.unavailable
        }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        let library = try device.makeLibrary(source: source, options: options)
        self.device = device
        self.queue = queue
        kernels = try .init(device: device, library: library)
    }
    func filter(_ image: SpatialCore.Image, pixelSize: Double, parameters: DiffusionCore.Parameters)
        async throws -> SpatialCore.Image
    {
        guard parameters.active, parameters.strength > 0, parameters.spatialScale > 0 else { return image }
        try Task.checkCancellation()
        let input = try kernels.buffer(
            image.pixels.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), 0) })
        let output = try kernels.allocate(input.length)
        guard let raw = queue.makeCommandBuffer() else { throw Failure.allocation }
        let command = MPSCommandBuffer(commandBuffer: raw)
        try kernels.encode(
            input: input, output: output, width: image.width, height: image.height, pixelSize: pixelSize,
            parameters: parameters, command: command)
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
        try Task.checkCancellation()
        let values = UnsafeBufferPointer(
            start: output.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: image.pixels.count)
        return try .init(
            width: image.width, height: image.height,
            pixels: values.map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) })
    }
}

/// Actor-owned cache and encoders. No CPU readback between PSF generation, FFT and blending.
/// Two cached spectra cover camera/enlarger stages; strength changes reuse their PSF.
nonisolated final class DiffusionMetalKernels {
    private struct Key: Hashable {
        let width: Int, height: Int, radius: Int, pixelSize: Double, parameters: DiffusionCore.Parameters
    }
    struct PSF { let spectrum: MTLBuffer, normalization: MTLBuffer }
    final class Plan {
        let width: Int, height: Int, shape: [NSNumber], spectrumShape: [NSNumber]
        let graph = MPSGraph()
        let rawKernel: MPSGraphTensor, kernelFFT: MPSGraphTensor, image: MPSGraphTensor,
            kernel: MPSGraphTensor, output: MPSGraphTensor
        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            shape = [3, NSNumber(value: height), NSNumber(value: width)]
            spectrumShape = [3, NSNumber(value: height), NSNumber(value: width / 2 + 1)]
            graph.options = .none
            let forward = MPSGraphFFTDescriptor()
            let inverse = MPSGraphFFTDescriptor()
            inverse.inverse = true
            inverse.scalingMode = .size
            rawKernel = graph.placeholder(shape: shape, dataType: .float32, name: "PSF")
            kernelFFT = graph.realToHermiteanFFT(rawKernel, axes: [1, 2], descriptor: forward, name: nil)
            image = graph.placeholder(shape: shape, dataType: .float32, name: "Image")
            kernel = graph.placeholder(
                shape: spectrumShape, dataType: .complexFloat32, name: "Cached PSF spectrum")
            let transform = graph.realToHermiteanFFT(image, axes: [1, 2], descriptor: forward, name: nil)
            let product = graph.multiplication(transform, kernel, name: nil)
            output = graph.HermiteanToRealFFT(product, axes: [1, 2], descriptor: inverse, name: nil)
        }
    }
    private let device: MTLDevice
    private let pad: MTLComputePipelineState, psf: MTLComputePipelineState, sum: MTLComputePipelineState,
        finish: MTLComputePipelineState, finishTile: MTLComputePipelineState
    #if targetEnvironment(simulator)
        private var simulatorKernels = [Key: SpatialCore.Image]()
    #endif
    private var plan: Plan?
    private var cache: [Key: PSF] = [:], recent = [Key]()
    init(device: MTLDevice, library: MTLLibrary) throws {
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw MetalDiffusion.Failure.unavailable
            }
            return try device.makeComputePipelineState(function: function)
        }
        self.device = device
        pad = try pipeline("diffusion_pad")
        psf = try pipeline("diffusion_psf")
        sum = try pipeline("diffusion_sum")
        finish = try pipeline("diffusion_finish")
        finishTile = try pipeline("diffusion_finish_tile")
    }
    func clear() {
        #if targetEnvironment(simulator)
            simulatorKernels.removeAll()
        #endif
        plan = nil
        cache.removeAll()
        recent.removeAll()
    }
    func encode(
        input: MTLBuffer, output: MTLBuffer, width: Int, height: Int, pixelSize: Double,
        parameters p: DiffusionCore.Parameters, command: MPSCommandBuffer
    ) throws {
        try Task.checkCancellation()
        let radius = try DiffusionCore.radius(
            width: width, height: height, pixelSize: pixelSize, parameters: p)
        func power(_ value: Int) -> Int {
            var n = 1
            while n < value { n *= 2 }
            return n
        }
        let fw = power(width + 2 * radius)
        let fh = power(height + 2 * radius)
        #if targetEnvironment(simulator)
            // Simulator's MPSGraph device descriptor raises an Objective-C exception on this runtime.
            // Commit the preceding GPU stages before native Accelerate reads their shared buffers.
            let predecessor = command.rootCommandBuffer
            command.commitAndContinue()
            predecessor.waitUntilCompleted()
            if let error = predecessor.error { throw error }
            var shapeP = p
            shapeP.strength = 0.5
            shapeP.active = true
            let key = Key(width: fw, height: fh, radius: radius, pixelSize: pixelSize, parameters: shapeP)
            let kernel: SpatialCore.Image
            if let cached = simulatorKernels[key] {
                kernel = cached
            } else {
                kernel = try DiffusionCore.kernel(radius: radius, pixelSize: pixelSize, parameters: p)
                simulatorKernels[key] = kernel
                if simulatorKernels.count > 2 {
                    simulatorKernels = [key: kernel]
                }
            }
            let pointer = input.contents().assumingMemoryBound(to: SIMD4<Float>.self)
            let pixels = (0..<width * height).map { i in
                SIMD3<Double>(Double(pointer[i].x), Double(pointer[i].y), Double(pointer[i].z))
            }
            let image = try SpatialCore.Image(width: width, height: height, pixels: pixels)
            let filtered = try DiffusionCore.convolve(image, kernel: kernel, radius: radius)
            let fraction = try DiffusionCore.scatter(strength: p.strength, family: p.family)
            let destination = output.contents().assumingMemoryBound(to: SIMD4<Float>.self)
            for i in pixels.indices {
                let value = pixels[i] * (1 - fraction) + filtered.pixels[i] * fraction
                destination[i] = SIMD4(Float(value.x), Float(value.y), Float(value.z), 0)
            }
            return
        #else
            let current: Plan
            if let plan, plan.width == fw, plan.height == fh {
                current = plan
            } else {
                current = Plan(width: fw, height: fh)
                plan = current
                cache.removeAll()
                recent.removeAll()
            }
            var shapeP = p
            shapeP.strength = 0.5
            shapeP.active = true
            let key = Key(width: fw, height: fh, radius: radius, pixelSize: pixelSize, parameters: shapeP)
            let kernel: PSF
            if let cached = cache[key] {
                kernel = cached
            } else {
                let components = try DiffusionCore.components(pixelSize: pixelSize, parameters: p).map {
                    SIMD4<Float>(Float($0.1.x), Float($0.1.y), Float($0.1.z), Float($0.0))
                }
                kernel = try makePSF(
                    plan: current, radius: radius, components: components, command: command)
                cache[key] = kernel
            }
            recent.removeAll { $0 == key }
            recent.append(key)
            while recent.count > 2 { cache.removeValue(forKey: recent.removeFirst()) }
            let padded = try allocate(3 * fw * fh * 4)
            let filtered = try allocate(3 * fw * fh * 4)
            let prepare = try encoder(command, pad, [input, padded])
            var dimensions = SIMD4<UInt32>(UInt32(width), UInt32(height), UInt32(fw), UInt32(fh))
            var border = UInt32(radius)
            var wholeSample: UInt32 = 0
            prepare.setBytes(&dimensions, length: 16, index: 2)
            prepare.setBytes(&border, length: 4, index: 3)
            prepare.setBytes(&wholeSample, length: 4, index: 4)
            prepare.dispatchThreads(
                MTLSize(width: fw, height: fh, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
            prepare.endEncoding()
            current.graph.encode(
                to: command,
                feeds: [
                    current.image: MPSGraphTensorData(padded, shape: current.shape, dataType: .float32),
                    current.kernel: MPSGraphTensorData(
                        kernel.spectrum, shape: current.spectrumShape, dataType: .complexFloat32),
                ], targetOperations: nil,
                resultsDictionary: [
                    current.output: MPSGraphTensorData(filtered, shape: current.shape, dataType: .float32)
                ], executionDescriptor: nil)
            let blend = try encoder(command, finish, [filtered, input, output, kernel.normalization])
            var fraction = Float(try DiffusionCore.scatter(strength: p.strength, family: p.family))
            blend.setBytes(&dimensions, length: 16, index: 4)
            blend.setBytes(&border, length: 4, index: 5)
            blend.setBytes(&fraction, length: 4, index: 6)
            dispatch(blend, finish, width * height)
        #endif
    }
    /// Transform a point-spread function sampled on the plan's grid. `samples` > 1 area-samples it.
    func makePSF(
        plan current: Plan, radius: Int, components: [SIMD4<Float>], samples: Int = 1,
        command: MPSCommandBuffer
    ) throws -> PSF {
        let fw = current.width, fh = current.height
        guard !components.isEmpty, components.allSatisfy({ $0.w.isFinite && $0.w > 0 }),
            2 * radius + 1 <= min(fw, fh)
        else { throw DiffusionCore.Failure.invalidParameter }
        let raw = try allocate(3 * fw * fh * 4)
        let spectrum = try allocate(3 * fh * (fw / 2 + 1) * 8)
        let normalization = try allocate(16)
        let groups = ((2 * radius + 1) * (2 * radius + 1) + 127) / 128
        let partial = try allocate(groups * 16)
        let values = try buffer(components)
        guard let blit = command.makeBlitCommandEncoder() else {
            throw MetalDiffusion.Failure.allocation
        }
        blit.fill(buffer: raw, range: 0..<raw.length, value: 0)
        blit.endEncoding()
        let encoder = try self.encoder(command, psf, [raw, partial, values])
        var shape = SIMD4<UInt32>(UInt32(radius), UInt32(fw), UInt32(fh), UInt32(components.count))
        var subsamples = UInt32(max(samples, 1))
        encoder.setBytes(&shape, length: MemoryLayout.size(ofValue: shape), index: 3)
        encoder.setBytes(&subsamples, length: 4, index: 4)
        encoder.dispatchThreadgroups(
            MTLSize(width: groups, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
        encoder.endEncoding()
        let reduce = try self.encoder(command, sum, [partial, normalization])
        var groupCount = UInt32(groups)
        reduce.setBytes(&groupCount, length: 4, index: 2)
        dispatch(reduce, sum, 1)
        current.graph.encode(
            to: command,
            feeds: [
                current.rawKernel: MPSGraphTensorData(raw, shape: current.shape, dataType: .float32)
            ],
            targetOperations: nil,
            resultsDictionary: [
                current.kernelFFT: MPSGraphTensorData(
                    spectrum, shape: current.spectrumShape, dataType: .complexFloat32)
            ], executionDescriptor: nil)
        return PSF(spectrum: spectrum, normalization: normalization)
    }

    /// Fixed transform size and buffers reused by every tile of one export.
    final class Workspace {
        let plan: Plan, padded: MTLBuffer, filtered: MTLBuffer
        fileprivate init(plan: Plan, padded: MTLBuffer, filtered: MTLBuffer) {
            self.plan = plan
            self.padded = padded
            self.filtered = filtered
        }
    }
    func workspace(width: Int, height: Int) throws -> Workspace {
        try Workspace(
            plan: Plan(width: width, height: height), padded: allocate(3 * width * height * 4),
            filtered: allocate(3 * width * height * 4))
    }
    /// Mirror-pad `input` and convolve it with `kernel`; the planar result stays in the workspace.
    func convolve(
        _ work: Workspace, kernel: PSF, input: MTLBuffer, width: Int, height: Int, radius: Int,
        mirrorsAtEdge: Bool = false, command: MPSCommandBuffer
    ) throws {
        let fw = work.plan.width, fh = work.plan.height
        guard width + 2 * radius <= fw, height + 2 * radius <= fh else {
            throw DiffusionCore.Failure.invalidParameter
        }
        let prepare = try encoder(command, pad, [input, work.padded])
        var dimensions = SIMD4<UInt32>(UInt32(width), UInt32(height), UInt32(fw), UInt32(fh))
        var border = UInt32(radius)
        var edge: UInt32 = mirrorsAtEdge ? 1 : 0
        prepare.setBytes(&dimensions, length: 16, index: 2)
        prepare.setBytes(&border, length: 4, index: 3)
        prepare.setBytes(&edge, length: 4, index: 4)
        prepare.dispatchThreads(
            MTLSize(width: fw, height: fh, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        prepare.endEncoding()
        work.plan.graph.encode(
            to: command,
            feeds: [
                work.plan.image: MPSGraphTensorData(
                    work.padded, shape: work.plan.shape, dataType: .float32),
                work.plan.kernel: MPSGraphTensorData(
                    kernel.spectrum, shape: work.plan.spectrumShape, dataType: .complexFloat32),
            ], targetOperations: nil,
            resultsDictionary: [
                work.plan.output: MPSGraphTensorData(
                    work.filtered, shape: work.plan.shape, dataType: .float32)
            ], executionDescriptor: nil)
    }
    /// Unnormalized convolution result as interleaved pixels. `finite` supplies ignored operands.
    func extract(
        _ work: Workspace, output: MTLBuffer, finite: MTLBuffer, width: Int, height: Int,
        radius: Int, command: MPSCommandBuffer
    ) throws {
        let ones = try buffer([SIMD4<Float>(repeating: 1)])
        let blend = try encoder(command, finish, [work.filtered, finite, output, ones])
        var dimensions = SIMD4<UInt32>(
            UInt32(width), UInt32(height), UInt32(work.plan.width), UInt32(work.plan.height))
        var border = UInt32(radius)
        var fraction: Float = 1
        blend.setBytes(&dimensions, length: 16, index: 4)
        blend.setBytes(&border, length: 4, index: 5)
        blend.setBytes(&fraction, length: 4, index: 6)
        dispatch(blend, finish, width * height)
    }
    /// Blend the near (in-tile) and far (proxy) parts with the unfiltered tile.
    func finishTile(
        _ work: Workspace?, near: PSF?, far: MTLBuffer?, farSum: MTLBuffer?, farGain: Float,
        original: MTLBuffer, output: MTLBuffer, width: Int, height: Int, radius: Int,
        fraction: Float, command: MPSCommandBuffer
    ) throws {
        guard (work != nil && near != nil) || (far != nil && farSum != nil) else {
            throw DiffusionCore.Failure.invalidParameter
        }
        let placeholder = original
        let blend = try encoder(
            command, finishTile,
            [work?.filtered ?? placeholder, original, output, near?.normalization ?? placeholder])
        blend.setBuffer(far ?? placeholder, offset: 0, index: 7)
        blend.setBuffer(farSum ?? placeholder, offset: 0, index: 8)
        var dimensions = SIMD4<UInt32>(
            UInt32(width), UInt32(height), UInt32(work?.plan.width ?? width),
            UInt32(work?.plan.height ?? height))
        var border = UInt32(radius)
        var p = SIMD4<Float>(fraction, farGain, 0, 0)
        var mode = SIMD2<UInt32>(near == nil ? 0 : 1, far == nil ? 0 : 1)
        blend.setBytes(&dimensions, length: 16, index: 4)
        blend.setBytes(&border, length: 4, index: 5)
        blend.setBytes(&p, length: 16, index: 6)
        blend.setBytes(&mode, length: 8, index: 9)
        dispatch(blend, finishTile, width * height)
    }
    func allocate(_ length: Int) throws -> MTLBuffer {
        guard length <= device.maxBufferLength,
            let result = device.makeBuffer(length: length, options: .storageModeShared)
        else { throw MetalDiffusion.Failure.allocation }
        return result
    }
    func buffer<T>(_ values: [T]) throws -> MTLBuffer {
        guard
            let result = values.withUnsafeBytes({
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            })
        else { throw MetalDiffusion.Failure.allocation }
        return result
    }
    private func encoder(
        _ command: MTLCommandBuffer, _ pipeline: MTLComputePipelineState, _ buffers: [MTLBuffer]
    ) throws -> MTLComputeCommandEncoder {
        guard let result = command.makeComputeCommandEncoder() else {
            throw MetalDiffusion.Failure.allocation
        }
        result.setComputePipelineState(pipeline)
        for (i, b) in buffers.enumerated() { result.setBuffer(b, offset: 0, index: i) }
        return result
    }
    private func dispatch(
        _ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, _ count: Int
    ) {
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(128, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
    }
}
