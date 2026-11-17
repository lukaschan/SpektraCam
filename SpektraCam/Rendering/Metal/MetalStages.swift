// Native verified-stage experiments; not yet the end-to-end photograph renderer.
import Foundation
import Metal

/// Reuses pipelines and submits work asynchronously. Safe math preserves missing-data NaNs.
actor MetalStages {
    enum Failure: Error { case unavailable, invalidShape, allocation, command }
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let curvePipeline: MTLComputePipelineState
    private let spectralPipeline: MTLComputePipelineState

    init(source: String) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.unavailable
        }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        let library = try device.makeLibrary(source: source, options: options)
        guard let curve = library.makeFunction(name: "density_curves"),
            let spectral = library.makeFunction(name: "spectral_xyz")
        else { throw Failure.unavailable }
        self.device = device
        self.queue = queue
        curvePipeline = try device.makeComputePipelineState(function: curve)
        spectralPipeline = try device.makeComputePipelineState(function: spectral)
    }
    func densities(_ input: [SIMD4<Float>], axis: [Float], curves: [SIMD4<Float>]) async throws -> [SIMD4<
        Float
    >] {
        guard axis.count == curves.count, axis.count >= 2, !input.isEmpty else { throw Failure.invalidShape }
        let buffers = try [buffer(input), buffer(axis), buffer(curves)]
        return try await execute(curvePipeline, inputs: buffers, count: input.count, samples: axis.count)
    }
    func xyz(_ input: [SIMD4<Float>], channels: [SIMD4<Float>], weights: [SIMD4<Float>]) async throws
        -> [SIMD4<Float>]
    {
        guard channels.count == weights.count, !channels.isEmpty, !input.isEmpty else {
            throw Failure.invalidShape
        }
        let packed = zip(channels, weights).flatMap { [$0.0, $0.1] }
        return try await execute(
            spectralPipeline, inputs: [buffer(input), buffer(packed)], count: input.count,
            samples: channels.count)
    }
    private func buffer<T>(_ values: [T]) throws -> MTLBuffer {
        guard
            let result = values.withUnsafeBytes({ bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            })
        else { throw Failure.allocation }
        return result
    }
    private func execute(_ pipeline: MTLComputePipelineState, inputs: [MTLBuffer], count: Int, samples: Int)
        async throws -> [SIMD4<Float>]
    {
        guard
            let output = device.makeBuffer(
                length: count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
            let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
        else { throw Failure.allocation }
        encoder.setComputePipelineState(pipeline)
        for (i, input) in inputs.enumerated() { encoder.setBuffer(input, offset: 0, index: i) }
        encoder.setBuffer(output, offset: 0, index: inputs.count)
        var shape = SIMD2<UInt32>(UInt32(count), UInt32(samples))
        encoder.setBytes(&shape, length: MemoryLayout.size(ofValue: shape), index: inputs.count + 1)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, pipeline.threadExecutionWidth * 4)
        encoder.dispatchGrid(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { completed in
                if let error = completed.error {
                    continuation.resume(throwing: error)
                } else if completed.status != .completed {
                    continuation.resume(throwing: Failure.command)
                } else {
                    continuation.resume()
                }
            }
            command.commit()
        }
        return Array(
            UnsafeBufferPointer(
                start: output.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: count))
    }
}
