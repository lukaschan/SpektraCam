// Native composition of the verified color, spatial and stochastic reference stages. GPLv3.
import Foundation

/// Double-precision native baseline including spectral UV/IR, diffusion and reference corrections.
/// Numerical oracle for the combined Metal graph used by the editor preview.
nonisolated struct FilmPipeline: Sendable {
    typealias RGB = SIMD3<Double>
    let recipe: EditRecipe
    let color: ColorPipeline
    let film: ModelLibrary.Profile
    let reference: ReferenceCorrectionCore
    /// Tone is a per-frame input operation; it does not alter spectral material setup.
    init(prepared: FilmPipeline, tone: EditRecipe.Tone) throws {
        try RawAdjustments.validate(tone)
        var recipe = prepared.recipe
        recipe.tone = tone
        self.recipe = recipe
        color = prepared.color
        film = prepared.film
        reference = prepared.reference
    }
    init(library: ModelLibrary, recipe: EditRecipe) throws {
        try RawAdjustments.validate(recipe.tone)
        guard recipe.numbers.values.allSatisfy(\.isFinite),
            recipe.number("film_render.density_curve_gamma") > 0,
            recipe.number("camera.film_format_mm") > 0
        else { throw SpectralCore.Failure.invalidShape }
        // Validate before converting numeric recipe fields to integers; malformed input must not trap.
        for path in ["film_render.grain.n_sub_layers", "film_render.halation.halation_n_bounces"] {
            let value = recipe.number(path)
            guard value.isFinite, value >= 1, value <= 100, value.rounded() == value else {
                throw SpectralCore.Failure.invalidShape
            }
        }
        self.recipe = recipe
        var preparation = recipe
        preparation.numbers["film_render.halation.boost_ev"] = 0  // handled spatially below
        preparation.flags["scanner.white_correction"] = false
        preparation.flags["scanner.black_correction"] = false
        color = try ColorPipeline(library: library, recipe: preparation)
        guard let film = library.index.profiles[recipe.filmID] else {
            throw ColorPipeline.Failure.unknownStock
        }
        self.film = film
        guard let paper = library.index.profiles[recipe.printID] else {
            throw ColorPipeline.Failure.unknownStock
        }
        reference = try .init(recipe: recipe, film: film, paper: paper, color: color)
    }
    func process(
        _ linearRGB: [RGB], width: Int, height: Int, stochastic: Bool = true, seed: UInt64 = 0
    )
        throws -> [RGB]
    {
        let image = try SpatialCore.Image(width: width, height: height, pixels: linearRGB)
        let pitch = recipe.number("camera.film_format_mm") * 1000 / Double(max(width, height))
        guard pitch.isFinite, pitch > 0 else { throw SpectralCore.Failure.invalidShape }
        let scale = pow(2, try color.autoExposureEV(linearRGB, width: width, height: height))
        let manual = pow(2, recipe.number("camera.exposure_compensation_ev"))
        var raw = image
        raw.pixels = linearRGB.map { color.exposure.raw($0 * scale) * manual }
        raw = try HighlightBoostCore.apply(
            raw, ev: number("film_render.halation", "boost_ev"),
            range: number("film_render.halation", "boost_range"),
            protectEV: number("film_render.halation", "protect_ev"))
        raw = try DiffusionCore.apply(
            raw, pixelSize: pitch, parameters: diffusion("camera.diffusion_filter"))
        let lens = recipe.number("camera.lens_blur_um")
        if lens > 0 { raw = raw.gaussian(RGB(repeating: lens / pitch)) }
        raw = try HalationCore.apply(raw, parameters: halation, pixelSizeMicrometers: pitch)
        if reference.filmingScale != 1 { raw.pixels = raw.pixels.map { $0 * reference.filmingScale } }
        let logRaw = raw.pixels.map(Self.logarithm)
        var density = image
        density.pixels = logRaw.map { color.filmCurve.density(at: $0) }
        if let development = color.coupledDevelopment {
            var inhibition = image
            inhibition.pixels = density.pixels.map {
                development.matrix.inhibition(from: development.positive ? development.maximum - $0 : $0)
            }
            let radius = number("film_render.dir_couplers", "diffusion_size_um")
            if radius > 0 {
                let gaussian = inhibition.gaussian(RGB(repeating: radius / pitch))
                let tail = inhibition.exponential(
                    RGB(repeating: number("film_render.dir_couplers", "diffusion_tail_um") / pitch))
                let weight = number("film_render.dir_couplers", "diffusion_tail_weight")
                for i in inhibition.pixels.indices {
                    inhibition.pixels[i] = gaussian.pixels[i] * (1 - weight) + tail.pixels[i] * weight
                }
            }
            density.pixels = logRaw.indices.map {
                development.beforeCouplers.density(at: logRaw[$0] - inhibition.pixels[$0])
            }
        }
        if stochastic {
            density = try GrainCore.apply(
                density, curves: color.filmCurve.values,
                layers: film.densityLayers.map { $0.map(ModelLibrary.vector) }, positive: film.positive,
                pixelSize: pitch, parameters: grain, seed: seed)
        }
        if let enlarger = color.enlarger, let curve = color.printCurve {
            var printRaw = image
            printRaw.pixels = density.pixels.map { enlarger.rawExposure($0) * reference.printingScale }
            printRaw = try DiffusionCore.apply(
                printRaw, pixelSize: pitch, parameters: diffusion("enlarger.diffusion_filter"))
            density.pixels = printRaw.pixels.map { curve.density(at: Self.logarithm($0)) }
        }
        var xyz = image
        xyz.pixels = density.pixels.map {
            let value = color.scanBasis.xyz($0)
            return reference.correct(
                RGB(
                    pow(10, log10(max(value.x, 0) + 1e-10)), pow(10, log10(max(value.y, 0) + 1e-10)),
                    pow(10, log10(max(value.z, 0) + 1e-10))))
        }
        if stochastic && !recipe.bypassesPrint && recipe.flag("print_render.glare.active") {
            let amount = number("print_render.glare", "percent")
            if amount > 0 {
                var field = image
                for i in field.pixels.indices {
                    var random = StatisticsCore.Stream(pixel: UInt64(i), domain: 1024, seed: seed)
                    let value = try random.lognormal(
                        mean: amount, standardDeviation: amount * number("print_render.glare", "roughness"))
                    field.pixels[i] = RGB(repeating: value)
                }
                field = field.gaussian(RGB(repeating: number("print_render.glare", "blur")))
                let basis = color.scanBasis
                let white =
                    zip(basis.illuminant, basis.cmfs).reduce(RGB.zero) { $0 + $1.0 * $1.1 }
                    / basis.normalization
                for i in xyz.pixels.indices { xyz.pixels[i] += white * (field.pixels[i].x / 100) }
            }
        }
        var output = image
        output.pixels = xyz.pixels.map {
            color.compression.compress(ColorPipeline.apply(color.scanMatrix, $0))
        }
        let scanBlur = recipe.number("scanner.lens_blur")
        if scanBlur > 0 { output = output.gaussian(RGB(repeating: scanBlur)) }
        let sigma = recipe.number("scanner.unsharp_mask[0]")
        let amount = recipe.number("scanner.unsharp_mask[1]")
        if sigma > 0 && amount > 0 {
            let blur = output.gaussian(RGB(repeating: sigma))
            for i in output.pixels.indices {
                output.pixels[i] += amount * (output.pixels[i] - blur.pixels[i])
            }
        }
        return output.pixels.map {
            let rgb = ColorPipeline.apply(color.encodingMatrix, $0)
            return RGB(
                ColorPipeline.encodeSRGB(rgb.x), ColorPipeline.encodeSRGB(rgb.y),
                ColorPipeline.encodeSRGB(rgb.z))
        }
    }
    private static func logarithm(_ v: RGB) -> RGB {
        RGB(log10(max(v.x, 0) + 1e-10), log10(max(v.y, 0) + 1e-10), log10(max(v.z, 0) + 1e-10))
    }
    private func number(_ prefix: String, _ field: String) -> Double {
        recipe.number(prefix + "." + field)
    }
    func diffusion(_ prefix: String) -> DiffusionCore.Parameters {
        var p = DiffusionCore.Parameters()
        p.active = recipe.flag(prefix + ".active")
        p.family = recipe.choice(prefix + ".filter_family")
        p.strength = number(prefix, "strength")
        p.spatialScale = number(prefix, "spatial_scale")
        p.warmth = number(prefix, "halo_warmth")
        p.intensity = RGB(
            number(prefix, "core_intensity"), number(prefix, "halo_intensity"),
            number(prefix, "bloom_intensity"))
        p.size = RGB(
            number(prefix, "core_size"), number(prefix, "halo_size"), number(prefix, "bloom_size"))
        return p
    }
    private func vector(_ prefix: String, _ field: String) -> RGB {
        RGB(number(prefix, field + "[0]"), number(prefix, field + "[1]"), number(prefix, field + "[2]"))
    }
    var halation: HalationCore.Parameters {
        let prefix = "film_render.halation"
        var p = HalationCore.Parameters()
        p.active = recipe.flag(prefix + ".active")
        p.scatterAmount = number(prefix, "scatter_amount")
        p.scatterScale = number(prefix, "scatter_spatial_scale")
        p.amount = number(prefix, "halation_amount")
        p.scale = number(prefix, "halation_spatial_scale")
        p.scatterCore = vector(prefix, "scatter_core_um")
        p.scatterTail = vector(prefix, "scatter_tail_um")
        p.tailWeight = vector(prefix, "scatter_tail_weight")
        p.strength = vector(prefix, "halation_strength")
        p.firstSigma = vector(prefix, "halation_first_sigma_um")
        p.bounces = Int(number(prefix, "halation_n_bounces"))
        p.decay = number(prefix, "halation_bounce_decay")
        p.renormalize = recipe.flag(prefix + ".halation_renormalize")
        return p
    }
    var grain: GrainCore.Parameters {
        let prefix = "film_render.grain"
        var p = GrainCore.Parameters()
        p.active = recipe.flag(prefix + ".active")
        p.sublayers = recipe.flag(prefix + ".sublayers_active")
        p.area = number(prefix, "particle_area_um2")
        p.scale = vector(prefix, "particle_scale")
        p.layerScale = vector(prefix, "particle_scale_layers")
        p.minimum = vector(prefix, "density_min")
        p.uniformity = vector(prefix, "uniformity")
        p.blur = number(prefix, "blur")
        p.dyeCloudBlur = number(prefix, "blur_dye_clouds_um")
        p.microstructure = SIMD2(
            number(prefix, "micro_structure[0]"), number(prefix, "micro_structure[1]"))
        p.simpleSublayers = Int(number(prefix, "n_sub_layers"))
        return p
    }
}
