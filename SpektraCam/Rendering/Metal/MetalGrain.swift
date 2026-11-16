import Foundation
import Metal

/// Verified GPU particle stage. The complete editor graph will retain its buffers on the GPU.
actor MetalGrain {
    enum Failure: Error { case unavailable, invalidParameter, allocation, command, sampling }
    private let device: MTLDevice, queue: MTLCommandQueue, kernel: MTLComputePipelineState
    init(source: String) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.unavailable
        }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        let library = try device.makeLibrary(source: source, options: options)
        guard let function = library.makeFunction(name: "particle_noise") else { throw Failure.unavailable }
        self.device = device
        self.queue = queue
        kernel = try device.makeComputePipelineState(function: function)
    }
    func particles(
        _ density: [SIMD4<Float>], maximum: SIMD3<Float>, particles: SIMD3<Float>, uniformity: SIMD3<Float>,
        seed: UInt64, domain: UInt32 = 0, pixelOffset: UInt64 = 0
    ) async throws -> [SIMD4<Float>] {
        guard !density.isEmpty, density.count <= UInt32.max, domain <= UInt32.max - 2,
            (0..<3).allSatisfy({
                maximum[$0].isFinite && maximum[$0] > 0 && particles[$0].isFinite && particles[$0] > 0
                    && uniformity[$0].isFinite && (0...1).contains(uniformity[$0])
            }),
            density.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        else { throw Failure.invalidParameter }
        try Task.checkCancellation()
        func four(_ v: SIMD3<Float>) -> SIMD4<Float> { .init(v.x, v.y, v.z, 0) }
        let input = try buffer(density)
        let parameters = try buffer([four(maximum), four(particles), four(uniformity)])
        guard let output = device.makeBuffer(length: input.length, options: .storageModeShared),
            let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
        else { throw Failure.allocation }
        encoder.setComputePipelineState(kernel)
        for (i, b) in [input, output, parameters].enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
        var shape = SIMD4<UInt32>(
            UInt32(density.count), domain, UInt32(truncatingIfNeeded: pixelOffset),
            UInt32(truncatingIfNeeded: pixelOffset >> 32))
        var key = SIMD2<UInt32>(UInt32(truncatingIfNeeded: seed), UInt32(truncatingIfNeeded: seed >> 32))
        encoder.setBytes(&shape, length: MemoryLayout.size(ofValue: shape), index: 3)
        encoder.setBytes(&key, length: MemoryLayout.size(ofValue: key), index: 4)
        encoder.dispatchGrid(
            MTLSize(width: density.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(128, kernel.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        let values = Array(
            UnsafeBufferPointer(
                start: output.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: density.count))
        guard values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw Failure.sampling
        }
        return values
    }
    private func buffer<T>(_ values: [T]) throws -> MTLBuffer {
        guard
            let result = values.withUnsafeBytes({
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            })
        else { throw Failure.allocation }
        return result
    }
}
