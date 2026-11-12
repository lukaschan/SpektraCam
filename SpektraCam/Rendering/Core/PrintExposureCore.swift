// Spectral enlarger and Kodak CC balance from spektrafilm 3bb2c2d. GPLv3.
import Foundation

nonisolated enum PrintExposureCore {
    typealias RGB = SIMD3<Double>
    struct Parameters: Sendable {
        var neutral = RGB(0, 65, 55)  // Cyan, Magenta, Yellow in Kodak CC units.
        var shift = RGB.zero
        var preflashShift = RGB.zero
        var preflashExposure = 0.0
        var printExposure = 1.0
        var compensate = true
        var normalize = true
    }
    struct Enlarger: Sendable {
        let channels: [RGB], base: [Double], sensitivity: [RGB]
        let printLight: [Double], preflash: RGB, factor: Double, printExposure: Double

        init(
            wavelengths: [Double], channels: [RGB], base: [Double], sensitivity: [RGB], illuminant: [Double],
            midgray: [Double], compensatedMidgray: [Double]?, parameters p: Parameters
        ) throws {
            let n = wavelengths.count
            guard n > 0,
                [channels.count, base.count, sensitivity.count, illuminant.count, midgray.count].allSatisfy({
                    $0 == n
                }),
                compensatedMidgray.map({ $0.count == n }) ?? true
            else { throw SpectralCore.Failure.invalidShape }
            self.channels = channels
            self.base = base
            self.sensitivity = sensitivity
            printExposure = p.printExposure
            let filteredLight = Self.filtered(illuminant, wavelengths: wavelengths, cc: p.neutral + p.shift)
            printLight = filteredLight
            let factor0 = Self.exposureFactor(midgray, light: filteredLight, sensitivity: sensitivity)
            let factorComp =
                compensatedMidgray.map {
                    Self.exposureFactor($0, light: filteredLight, sensitivity: sensitivity)
                } ?? 1
            if p.compensate && !p.normalize {
                factor = factorComp / factor0
            } else if p.normalize && p.compensate {
                factor = factorComp
            } else if p.normalize {
                factor = factor0
            } else {
                factor = 1
            }
            if p.preflashExposure > 0 {
                let flashLight = Self.filtered(
                    illuminant, wavelengths: wavelengths, cc: p.neutral + p.preflashShift)
                preflash =
                    Self.integrate(base, light: flashLight, sensitivity: sensitivity) * p.preflashExposure
            } else {
                preflash = .zero
            }
        }
        func expose(_ density: RGB) -> RGB {
            let raw = rawExposure(density)
            return RGB(
                log10(max(raw.x, 0) + 1e-10), log10(max(raw.y, 0) + 1e-10), log10(max(raw.z, 0) + 1e-10))
        }
        /// Linear print exposure, before enlarger diffusion and its final logarithm.
        func rawExposure(_ density: RGB) -> RGB {
            var raw = baseExposure(density)
            for ch in 0..<3 {
                let initialLog = log10(max(raw[ch], 0) + 1e-10)
                raw[ch] = pow(10, initialLog) * printExposure
            }
            return raw
        }
        /// An open source perforation contains neither dye nor the stock's base density.
        var clearExposure: RGB {
            Self.integrate(Array(repeating: 0, count: base.count), light: printLight, sensitivity: sensitivity)
                * factor * printExposure + preflash * printExposure
        }
        /// Stock reference calculations use the balanced/preflashed exposure before print gain.
        func baseExposure(_ density: RGB) -> RGB {
            var raw = RGB.zero
            for i in channels.indices {
                let spectrum =
                    density.x * channels[i].x + density.y * channels[i].y + density.z * channels[i].z
                    + base[i]
                let value = pow(10, -spectrum) * printLight[i]
                if !value.isNaN { raw += sensitivity[i] * value }
            }
            return raw * factor + preflash
        }
        private static func filtered(_ light: [Double], wavelengths: [Double], cc: RGB) -> [Double] {
            let transmittance = RGB(pow(10, -cc.x / 100), pow(10, -cc.y / 100), pow(10, -cc.z / 100))
            return wavelengths.indices.map { i in
                let wl = wavelengths[i]
                let cyan = -erf((wl - 607) / 8) * 0.5 + 0.5
                let magenta = (wl <= 550 ? -erf((wl - 500) / 8) : erf((wl - 610) / 8)) * 0.5 + 0.5
                let yellow = erf((wl - 516) / 12) * 0.5 + 0.5
                let filtered =
                    RGB(1, 1, 1) - (RGB(1, 1, 1) - RGB(cyan, magenta, yellow))
                    * (RGB(1, 1, 1) - transmittance)
                return light[i] * filtered.x * filtered.y * filtered.z
            }
        }
        private static func integrate(_ density: [Double], light: [Double], sensitivity: [RGB]) -> RGB {
            var result = RGB.zero
            for i in density.indices {
                let value = pow(10, -density[i]) * light[i]
                if !value.isNaN { result += sensitivity[i] * value }
            }
            return result
        }
        private static func exposureFactor(_ midgray: [Double], light: [Double], sensitivity: [RGB]) -> Double
        {
            let raw = integrate(midgray, light: light, sensitivity: sensitivity)
            return 1 / exp((log(max(raw.x, 1e-10)) + log(max(raw.y, 1e-10)) + log(max(raw.z, 1e-10))) / 3)
        }
    }
}
