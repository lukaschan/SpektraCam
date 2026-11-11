// Reference FIR/IIR Gaussian and exponential mixture from spektrafilm 3bb2c2d. GPLv3.
import Foundation

nonisolated enum SpatialCore {
    typealias RGB = SIMD3<Double>
    struct Image: Sendable {
        let width: Int, height: Int
        var pixels: [RGB]
        init(width: Int, height: Int, pixels: [RGB]) throws {
            guard width > 0, height > 0, pixels.count == width * height else {
                throw SpectralCore.Failure.invalidShape
            }
            self.width = width
            self.height = height
            self.pixels = pixels
        }
        func gaussian(_ sigma: RGB, truncate: Double = 3) -> Image {
            var output = self
            for channel in 0..<3 {
                let input = pixels.map { $0[channel] }
                let filtered =
                    sigma[channel] >= 3
                    ? iir(input, sigma: sigma[channel])
                    : fir(input, sigma: sigma[channel], truncate: truncate)
                for i in filtered.indices { output.pixels[i][channel] = filtered[i] }
            }
            return output
        }
        func exponential(_ decay: RGB) -> Image {
            // Preserve the upstream fitted amplitudes, including their 0.9999 sum.
            let fit = [(0.1633, 0.5360), (0.6496, 1.5236), (0.1870, 2.7684)]
            var result = self
            result.pixels = Array(repeating: .zero, count: pixels.count)
            for (amplitude, ratio) in fit {
                let component = gaussian(decay * ratio)
                for i in pixels.indices { result.pixels[i] += component.pixels[i] * amplitude }
            }
            return result
        }
        private func fir(_ input: [Double], sigma: Double, truncate: Double) -> [Double] {
            guard sigma > 0 else { return input }
            let radius = Int(truncate * sigma + 0.5)
            var weights = (-radius...radius).map { exp(-0.5 * pow(Double($0) / sigma, 2)) }
            let sum = weights.reduce(0, +)
            weights = weights.map { $0 / sum }
            func reflect(_ index: Int, _ count: Int) -> Int {
                let period = 2 * count
                let position = ((index % period) + period) % period
                return position < count ? position : period - 1 - position
            }
            var temporary = input
            var output = input
            for y in 0..<height {
                for x in 0..<width {
                    var value = 0.0
                    for k in -radius...radius {
                        value += input[reflect(y + k, height) * width + x] * weights[k + radius]
                    }
                    temporary[y * width + x] = value
                }
            }
            for y in 0..<height {
                for x in 0..<width {
                    var value = 0.0
                    for k in -radius...radius {
                        value += temporary[y * width + reflect(x + k, width)] * weights[k + radius]
                    }
                    output[y * width + x] = value
                }
            }
            return output
        }
        private func iir(_ input: [Double], sigma: Double) -> [Double] {
            let b = SpatialCore.iirCoefficients(sigma)
            var temporary = input
            var output = input
            for y in 0..<height {
                var s1 = input[y * width]
                var s2 = s1
                var s3 = s1
                for x in 0..<width {
                    let value = b.x * input[y * width + x] + b.y * s1 + b.z * s2 + b.w * s3
                    temporary[y * width + x] = value
                    s3 = s2
                    s2 = s1
                    s1 = value
                }
                s1 = temporary[y * width + width - 1]
                s2 = s1
                s3 = s1
                for x in stride(from: width - 1, through: 0, by: -1) {
                    let value = b.x * temporary[y * width + x] + b.y * s1 + b.z * s2 + b.w * s3
                    temporary[y * width + x] = value
                    s3 = s2
                    s2 = s1
                    s1 = value
                }
            }
            for x in 0..<width {
                var s1 = temporary[x]
                var s2 = s1
                var s3 = s1
                for y in 0..<height {
                    let value = b.x * temporary[y * width + x] + b.y * s1 + b.z * s2 + b.w * s3
                    output[y * width + x] = value
                    s3 = s2
                    s2 = s1
                    s1 = value
                }
                s1 = output[(height - 1) * width + x]
                s2 = s1
                s3 = s1
                for y in stride(from: height - 1, through: 0, by: -1) {
                    let value = b.x * output[y * width + x] + b.y * s1 + b.z * s2 + b.w * s3
                    output[y * width + x] = value
                    s3 = s2
                    s2 = s1
                    s1 = value
                }
            }
            return output
        }
    }
    /// B, B1, B2, B3 for the reference Young–van Vliet recursive filter.
    /// Standard deviation the filter actually applies for a nominal `sigma`. The recursive
    /// approximation is wider than nominal and its ratio changes with scale, so a blur moved to
    /// another resolution must match this width, not the nominal value.
    static func effectiveDeviation(_ sigma: Double) -> Double {
        if sigma <= 0 { return 0 }
        if sigma < 3 {
            let radius = Int(3 * sigma + 0.5)
            var total = 0.0, moment = 0.0
            for k in -radius...radius {
                let weight = exp(-0.5 * pow(Double(k) / sigma, 2))
                total += weight
                moment += weight * Double(k * k)
            }
            return sqrt(moment / total)
        }
        let b = iirCoefficients(sigma)
        let mean = (b.y + 2 * b.z + 3 * b.w) / b.x
        // Forward and backward passes each add the causal response's variance.
        return sqrt(2 * ((b.y + 4 * b.z + 9 * b.w) / b.x + mean * mean))
    }
    /// Nominal sigma whose applied width is closest to `deviation`.
    static func sigma(forEffectiveDeviation deviation: Double) -> Double {
        func solve(_ low: Double, _ high: Double) -> Double {
            var low = low, high = high
            for _ in 0..<60 {
                let middle = 0.5 * (low + high)
                if effectiveDeviation(middle) < deviation { low = middle } else { high = middle }
            }
            return 0.5 * (low + high)
        }
        // The short exact kernel ends just below sigma 3 and the recursive filter starts wider.
        let shortest = 3.0, widestExact = 2.999
        let recursive = effectiveDeviation(shortest), exact = effectiveDeviation(widestExact)
        if deviation >= recursive { return solve(shortest, max(4 * deviation, 6)) }
        if deviation <= exact { return solve(1e-3, widestExact) }
        return deviation - exact < recursive - deviation ? widestExact : shortest
    }
    static func iirCoefficients(_ sigma: Double) -> SIMD4<Double> {
        let q = sigma >= 2.5 ? 0.98711 * sigma - 0.96330 : 3.97156 - 4.14554 * sqrt(1 - 0.26891 * sigma)
        let q2 = q * q
        let q3 = q2 * q
        let b0 = 1.57825 + 2.44413 * q + 1.4281 * q2 + 0.422205 * q3
        let b1 = 2.44413 * q + 2.85619 * q2 + 1.26661 * q3
        let b2 = -(1.4281 * q2 + 1.26661 * q3)
        let b3 = 0.422205 * q3
        return SIMD4(1 - (b1 + b2 + b3) / b0, b1 / b0, b2 / b0, b3 / b0)
    }
}
