import Foundation
import Metal

@main struct Checks {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = try String(
            contentsOf: root.appendingPathComponent("SpektraCam/Resources/ModelData/Grain.metalSource"),
            encoding: .utf8)
        // Independent official vectors anchor the integer RNG before testing its distributions.
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        let helper = """
            kernel void check_words(device const uint4* counters [[buffer(0)]],device const uint2* keys [[buffer(1)]],
                                    device uint4* output [[buffer(2)]],uint i [[thread_position_in_grid]]) {
                if(i<3)output[i]=grain_philox(counters[i],keys[i]);
            }
            """
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        let library = try await device.makeLibrary(source: source + helper, options: options)
        let pipeline = try await device.makeComputePipelineState(
            function: library.makeFunction(name: "check_words")!)
        let counters: [SIMD4<UInt32>] = [
            .zero, .init(repeating: .max), .init(0x243f_6a88, 0x85a3_08d3, 0x1319_8a2e, 0x0370_7344),
        ]
        let keys: [SIMD2<UInt32>] = [.zero, .init(repeating: .max), .init(0xa409_3822, 0x299f_31d0)]
        let expected: [SIMD4<UInt32>] = [
            .init(0x6627_e8d5, 0xe169_c58d, 0xbc57_ac4c, 0x9b00_dbd8),
            .init(0x408f_276d, 0x41c8_3b0e, 0xa20b_c7c6, 0x6d54_51fd),
            .init(0xd16c_fe09, 0x94fd_cceb, 0x5001_e420, 0x2412_6ea1),
        ]
        func buffer<T>(_ values: [T]) -> MTLBuffer {
            values.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)!
            }
        }
        let command = queue.makeCommandBuffer()!
        let encoder = command.makeComputeCommandEncoder()!
        let output = buffer(counters)
        encoder.setComputePipelineState(pipeline)
        for (i, b) in [buffer(counters), buffer(keys), output].enumerated() {
            encoder.setBuffer(b, offset: 0, index: i)
        }
        encoder.dispatchGrid(
            MTLSize(width: 3, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 3, height: 1, depth: 1))
        encoder.endEncoding()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { done in
                if let error = done.error { c.resume(throwing: error) } else { c.resume() }
            }
            command.commit()
        }
        let words = Array(
            UnsafeBufferPointer(
                start: output.contents().assumingMemoryBound(to: SIMD4<UInt32>.self), count: 3))
        precondition(words == expected, "GPU Philox failed official known-answer vectors")
        let gpu = try MetalGrain(source: source)
        let count = 200_000
        let density = Array(repeating: SIMD4<Float>(0.5, 0.5, 0.5, 0), count: count)
        var tested = 0
        for lambda in [0.01, 0.5, 5, 9.99, 10, 30, 100, 10000, 1e8, 1e12] {
            let result = try await gpu.particles(
                density, maximum: SIMD3(repeating: 1), particles: SIMD3(repeating: Float(2 * lambda)),
                uniformity: .zero, seed: 20_261_031)
            for ch in 0..<3 {
                let mean = 0.5
                let variance = 1 / (4 * lambda)
                let sum = result.reduce(0.0) { $0 + Double($1[ch]) - mean }
                let squares = result.reduce(0.0) { $0 + pow(Double($1[ch]) - mean, 2) }
                let bias = sum / Double(count)
                let actualVariance = squares / Double(count) - bias * bias
                precondition(
                    abs(bias) < 7 * sqrt(variance / Double(count)) + Double(Float(0.5).ulp),
                    "GPU Poisson mean lambda \(lambda), ch \(ch): \(bias)")
                precondition(
                    abs(actualVariance / variance - 1) < 7 * sqrt((2 + 1 / lambda) / Double(count)) + 0.003,
                    "GPU Poisson variance lambda \(lambda), ch \(ch): \(actualVariance/variance)")
                tested += count
            }
        }
        for uniformity in [0.97, 1.0] {
            for value in [0.0, 0.2, 1.1, 2.2, 2.5] {
                let pixels = Array(repeating: SIMD4<Float>(repeating: Float(value)), count: count)
                let values = try await gpu.particles(
                    pixels, maximum: SIMD3(repeating: 2.2), particles: SIMD3(repeating: 120),
                    uniformity: SIMD3(repeating: Float(uniformity)), seed: 42)
                let law = try GrainCore.Particle(
                    density: value, maximum: 2.2, particles: 120, uniformity: uniformity)
                for ch in 0..<3 {
                    let bias = values.reduce(0.0) { $0 + Double($1[ch]) - law.mean } / Double(count)
                    let variance =
                        values.reduce(0.0) { $0 + pow(Double($1[ch]) - law.mean - bias, 2) } / Double(count)
                    precondition(
                        abs(bias) < 8 * sqrt(law.variance / Double(count)) + 1e-6, "GPU particle mean")
                    precondition(
                        abs(variance / law.variance - 1) < 8 * sqrt((2 + 1 / law.meanCount) / Double(count))
                            + 0.005, "GPU particle variance \(value), \(uniformity): \(variance/law.variance)"
                    )
                    tested += count
                }
            }
        }
        let part = Array(density.prefix(1024))
        let offset = UInt64(UInt32.max) - 128
        let a = try await gpu.particles(
            part, maximum: SIMD3(repeating: 1), particles: SIMD3(repeating: 100),
            uniformity: SIMD3(repeating: 0.98), seed: 55, pixelOffset: offset)
        let b = try await gpu.particles(
            Array(part.prefix(512)), maximum: SIMD3(repeating: 1), particles: SIMD3(repeating: 100),
            uniformity: SIMD3(repeating: 0.98), seed: 55, pixelOffset: offset)
        let c = try await gpu.particles(
            Array(part.suffix(512)), maximum: SIMD3(repeating: 1), particles: SIMD3(repeating: 100),
            uniformity: SIMD3(repeating: 0.98), seed: 55, pixelOffset: offset + 512)
        precondition(a == b + c, "GPU grain changes with tile traversal or loses 64-bit pixel position")
        let n = Double(a.count)
        let means = (0..<3).map { ch in a.reduce(0.0) { $0 + Double($1[ch]) } / n }
        let variances = (0..<3).map { ch in a.reduce(0.0) { $0 + pow(Double($1[ch])-means[ch],2) } / n }
        let cross = a.reduce(0.0) { $0 + (Double($1.x)-means[0])*(Double($1.y)-means[1]) } / n
        let adjacent = zip(a.dropLast(),a.dropFirst()).reduce(0.0) { $0 + (Double($1.0.x)-means[0])*(Double($1.1.x)-means[0]) } / (n-1)
        precondition(abs(cross/sqrt(variances[0]*variances[1]))<0.15, "Grain channels are correlated")
        precondition(abs(adjacent/variances[0])<0.15, "Adjacent grain pixels are correlated")
        print(
            "PASS: GPU Philox official vectors, \(tested) Poisson/particle samples (lambda 0.01…1e12), saturated-density uniformity and 64-bit tile stability"
        )
    }
}
