// Deterministic color path composed from verified spektrafilm stages. GPLv3.
import Foundation

/// Explicit color-only policy: source spatial/stochastic stages are disabled.
/// This CPU implementation is the end-to-end baseline for subsequent Metal work.
nonisolated struct ColorPipeline: Sendable {
    typealias RGB = SIMD3<Double>
    enum Failure: Error {
        case unsupportedRecipe, unknownStock
        case unsupportedControl(String)
    }
    let recipe: EditRecipe
    let exposure: UpsamplingCore.FilmExposure
    let filmCurve: SpectralCore.DensityCurve
    let coupledDevelopment: CouplerCore.NonSpatialDevelopment?
    let enlarger: PrintExposureCore.Enlarger?
    let printCurve: SpectralCore.DensityCurve?
    let scanBasis: SpectralCore.SpectralBasis
    let scanMatrix: [RGB]
    let compression: GamutCore.CAM16Compression
    let encodingMatrix: [RGB]
    let meteringY: RGB

    init(library: ModelLibrary, recipe: EditRecipe) throws {
        guard (1...EditRecipe.currentVersion).contains(recipe.version), recipe.upstreamRevision == library.index.revision else {
            throw Failure.unsupportedRecipe
        }
        guard let film = library.index.profiles[recipe.filmID],
            let paper = library.index.profiles[recipe.printID]
        else { throw Failure.unknownStock }
        for key in ["film_render.halation.boost_ev"]
        where recipe.number(key) != 0 {
            throw Failure.unsupportedControl(key)
        }
        for key in ["scanner.white_correction", "scanner.black_correction"] where recipe.flag(key) {
            throw Failure.unsupportedControl(key)
        }
        self.recipe = recipe
        func filter(_ name: String) -> RGB {
            RGB(
                recipe.number("camera." + name + "[0]"), recipe.number("camera." + name + "[1]"),
                recipe.number("camera." + name + "[2]"))
        }
        let exposure = try library.exposure(stock: film.id, uv: filter("filter_uv"), ir: filter("filter_ir"))
        self.exposure = exposure
        let curveValues = film.densityCurves.map(ModelLibrary.vector)
        let minimum = curveValues.reduce(RGB(repeating: .infinity)) {
            RGB(min($0.x, $1.x), min($0.y, $1.y), min($0.z, $1.z))
        }
        let normalized = curveValues.map { $0 - minimum }
        let gamma = recipe.number("film_render.density_curve_gamma")
        filmCurve = try .init(axis: film.logExposure, values: normalized, gamma: gamma)
        if recipe.flag("film_render.dir_couplers.active") {
            func tuple(_ key: String, _ length: Int) -> [Double] {
                (0..<length).map { recipe.number("film_render.dir_couplers." + key + "[\($0)]") }
            }
            let same = tuple("gamma_samelayer_rgb", 3)
            let r = tuple("gamma_interlayer_r_to_gb", 2)
            let g = tuple("gamma_interlayer_g_to_rb", 2)
            let b = tuple("gamma_interlayer_b_to_rg", 2)
            let selfGain = recipe.number("film_render.dir_couplers.inhibition_samelayer")
            let interGain = recipe.number("film_render.dir_couplers.inhibition_interlayer")
            let amount = recipe.number("film_render.dir_couplers.amount")
            let matrix = try CouplerCore.Matrix(rows: [
                RGB(same[0] * selfGain, r[0] * interGain, r[1] * interGain) * amount,
                RGB(g[0] * interGain, same[1] * selfGain, g[1] * interGain) * amount,
                RGB(b[0] * interGain, b[1] * interGain, same[2] * selfGain) * amount,
            ])
            coupledDevelopment = try .init(
                axis: film.logExposure, normalizedCurves: normalized, gamma: gamma, matrix: matrix,
                positive: film.positive)
        } else {
            coupledDevelopment = nil
        }
        let filmBasis = try SpectralCore.SpectralBasis(
            channels: film.channels.map(ModelLibrary.vector), base: film.base,
            illuminant: film.viewingIlluminant, cmfs: library.index.cmfs.map(ModelLibrary.vector))
        if recipe.bypassesPrint {
            enlarger = nil
            printCurve = nil
        } else {
            let midgrayCurve = try SpectralCore.DensityCurve(
                axis: film.logExposure, values: curveValues, gamma: gamma)
            func midgray(_ ev: Double) -> [Double] {
                let raw = exposure.raw(RGB(repeating: 0.184 * pow(2, ev)))
                let logRaw = RGB(log10(raw.x + 1e-10), log10(raw.y + 1e-10), log10(raw.z + 1e-10))
                return filmBasis.densitySpectrum(midgrayCurve.density(at: logRaw))
            }
            var p = PrintExposureCore.Parameters()
            let neutral = library.index.neutralFilters[paper.id]?[film.id] ?? [0, 65, 55]
            p.neutral = RGB(
                recipe.numbers["enlarger.c_filter_neutral"] ?? neutral[0],
                recipe.numbers["enlarger.m_filter_neutral"] ?? neutral[1],
                recipe.numbers["enlarger.y_filter_neutral"] ?? neutral[2])
            p.shift = RGB(
                0, recipe.number("enlarger.m_filter_shift"), recipe.number("enlarger.y_filter_shift"))
            p.preflashShift = RGB(
                0, recipe.number("enlarger.preflash_m_filter_shift"),
                recipe.number("enlarger.preflash_y_filter_shift"))
            p.preflashExposure = recipe.number("enlarger.preflash_exposure")
            p.printExposure = recipe.number("enlarger.print_exposure")
            p.compensate = recipe.flag("enlarger.print_exposure_compensation")
            p.normalize = recipe.flag("enlarger.normalize_print_exposure")
            enlarger = try .init(
                wavelengths: library.index.wavelengths, channels: film.channels.map(ModelLibrary.vector),
                base: film.base, sensitivity: paper.sensitivity.map(ModelLibrary.vector),
                illuminant: library.index.enlargerIlluminant, midgray: midgray(0),
                compensatedMidgray: p.compensate
                    ? midgray(recipe.number("camera.exposure_compensation_ev")) : nil, parameters: p)
            var morph = PrintChemistryCore.Parameters()
            let prefix = "print_render.density_curves_morph."
            morph.active = recipe.flag(prefix + "active")
            morph.gamma = recipe.number(prefix + "gamma_factor")
            morph.fastGamma = recipe.number(prefix + "gamma_factor_fast")
            morph.slowGamma = recipe.number(prefix + "gamma_factor_slow")
            morph.redGamma = recipe.number(prefix + "gamma_factor_red")
            morph.greenGamma = recipe.number(prefix + "gamma_factor_green")
            morph.blueGamma = recipe.number(prefix + "gamma_factor_blue")
            morph.exhaustion = recipe.number(prefix + "developer_exhaustion")
            let model = try PrintChemistryCore.Model(
                centers: paper.centers, amplitudes: paper.amplitudes, sigmas: paper.sigmas)
            printCurve = try .init(
                axis: paper.logExposure,
                values: model.curves(axis: paper.logExposure, parameters: morph, positive: paper.positive))
        }
        let scan = recipe.bypassesPrint ? film : paper
        scanBasis = try .init(
            channels: scan.channels.map(ModelLibrary.vector), base: scan.base,
            illuminant: scan.viewingIlluminant, cmfs: library.index.cmfs.map(ModelLibrary.vector))
        scanMatrix = scan.scanMatrix.map(ModelLibrary.vector)
        compression = try library.outputCompression()
        encodingMatrix = library.index.rgbRoundTrip.map(ModelLibrary.vector)
        meteringY = ModelLibrary.vector(library.index.meteringY)
    }
    func process(_ linearRGB: [RGB], width: Int, height: Int) throws -> [RGB] {
        guard linearRGB.count == width * height, width > 0, height > 0 else {
            throw SpectralCore.Failure.invalidShape
        }
        let autoEV = try autoExposureEV(linearRGB, width: width, height: height)
        let autoScale = pow(2, autoEV)
        let manualScale = pow(2, recipe.number("camera.exposure_compensation_ev"))
        return linearRGB.map { pixel in
            let raw = exposure.raw(pixel * autoScale) * manualScale
            let logRaw = RGB(
                log10(max(raw.x, 0) + 1e-10), log10(max(raw.y, 0) + 1e-10), log10(max(raw.z, 0) + 1e-10))
            let filmDensity = coupledDevelopment?.density(at: logRaw) ?? filmCurve.density(at: logRaw)
            let density: RGB
            if let enlarger, let printCurve {
                density = printCurve.density(at: enlarger.expose(filmDensity))
            } else {
                density = filmDensity
            }
            var xyz = scanBasis.xyz(density)
            for ch in 0..<3 { xyz[ch] = pow(10, log10(max(xyz[ch], 0) + 1e-10)) }
            let rgb = compression.compress(Self.apply(scanMatrix, xyz))
            let encodedInput = Self.apply(encodingMatrix, rgb)
            return RGB(
                Self.encodeSRGB(encodedInput.x), Self.encodeSRGB(encodedInput.y),
                Self.encodeSRGB(encodedInput.z))
        }
    }
    func autoExposureEV(_ linearRGB: [RGB], width: Int, height: Int) throws -> Double {
        guard recipe.flag("camera.auto_exposure") else { return 0 }
        let luminance = linearRGB.map { $0.x * meteringY.x + $0.y * meteringY.y + $0.z * meteringY.z }
        let image = try MeteringCore.Image(width: width, height: height, luminance: luminance)
        return try image.smallPreview().exposureEV(method: recipe.choice("camera.auto_exposure_method"))
    }
    static func apply(_ basis: [RGB], _ v: RGB) -> RGB {
        basis[0] * v.x + basis[1] * v.y + basis[2] * v.z
    }
    static func encodeSRGB(_ x: Double) -> Double {
        x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }
}
