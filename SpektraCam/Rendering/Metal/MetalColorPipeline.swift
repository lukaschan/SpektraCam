import Foundation
import Metal

/// GPU implementation of the explicit color-only pipeline; no main-thread waits.
actor MetalColorPipeline {
    struct Frame: Sendable { let pixels: [SIMD4<Float>], gpuSeconds: Double }
    enum Failure: Error { case unavailable, allocation, invalidShape, command }
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let kernel: MTLComputePipelineState

    init(source: String) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.unavailable
        }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        let library = try device.makeLibrary(source: source, options: options)
        guard let function = library.makeFunction(name: "color_pipeline") else { throw Failure.unavailable }
        self.device = device
        self.queue = queue
        kernel = try device.makeComputePipelineState(function: function)
    }
    func process(
        _ input: [SIMD4<Float>], width: Int, height: Int, pipeline: ColorPipeline,
        autoExposureEV: Double? = nil
    ) async throws -> Frame {
        guard width > 0, height > 0, input.count == width * height else { throw Failure.invalidShape }
        try Task.checkCancellation()
        let autoEV: Double
        if let autoExposureEV {
            autoEV = autoExposureEV
        } else if pipeline.recipe.flag("camera.auto_exposure") {
            autoEV = try pipeline.autoExposureEV(
                input.map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) }, width: width, height: height)
        } else {
            autoEV = 0
        }
        let model = try MetalModelResources(device: device, pipeline: pipeline)
        var uniforms = model.uniforms
        uniforms[0].y = Float(pow(2, autoEV))
        let inputBuffer = try buffer(input)
        let uniformBuffer = try buffer(uniforms)
        guard
            let output = device.makeBuffer(
                length: input.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
            let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
        else { throw Failure.allocation }
        encoder.setComputePipelineState(kernel)
        let buffers = [inputBuffer, output] + model.buffers + [uniformBuffer]
        for (i, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: i) }
        var shape = model.shape
        shape.x = UInt32(input.count)
        var flags = model.flags
        encoder.setBytes(&shape, length: MemoryLayout.size(ofValue: shape), index: 10)
        encoder.setBytes(&flags, length: MemoryLayout.size(ofValue: flags), index: 11)
        let threads = min(kernel.maxTotalThreadsPerThreadgroup, kernel.threadExecutionWidth * 4)
        encoder.dispatchGrid(
            MTLSize(width: input.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
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
        let pixels = Array(
            UnsafeBufferPointer(
                start: output.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: input.count))
        return Frame(pixels: pixels, gpuSeconds: max(0, command.gpuEndTime - command.gpuStartTime))
    }
    private func buffer<T>(_ values: [T]) throws -> MTLBuffer {
        guard
            let buffer = values.withUnsafeBytes({
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            })
        else { throw Failure.allocation }
        return buffer
    }
}
