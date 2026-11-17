import Foundation
import Metal

@main struct Checks {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "MetalDispatchChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No accessible Metal device"])
        }
        let source = """
            #include <metal_stdlib>
            using namespace metal;
            kernel void fill(device uint *output [[buffer(0)]], constant uint2 &size [[buffer(1)]],
                             uint2 p [[thread_position_in_grid]]) {
                if(p.x >= size.x || p.y >= size.y) return;
                uint i = p.y * size.x + p.x;
                output[i] = i;
            }
            """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "fill")!)
        for (width, height) in [(1, 1), (127, 1), (128, 1), (129, 1), (517, 337)] {
            let count = width * height
            let sentinel = UInt32.max
            let buffer = device.makeBuffer(length: (count + 128) * 4, options: .storageModeShared)!
            let pixels = buffer.contents().assumingMemoryBound(to: UInt32.self)
            pixels.initialize(repeating: sentinel, count: count + 128)
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            var size = SIMD2<UInt32>(UInt32(width), UInt32(height))
            encoder.setBytes(&size, length: MemoryLayout.size(ofValue: size), index: 1)
            encoder.dispatchGrid(
                MTLSize(width: width, height: height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            precondition(command.status == .completed, "GPU dispatch failed: \(String(describing: command.error))")
            precondition((0..<count).allSatisfy { pixels[$0] == UInt32($0) }, "Missing or aliased pixels")
            precondition((count..<count + 128).allSatisfy { pixels[$0] == sentinel }, "Out-of-bounds writes")
        }
        print("PASS: uniform Metal dispatch covers tiny, aligned, partial, and odd 2D grids; canaries intact")
    }
}
