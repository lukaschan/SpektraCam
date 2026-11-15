// Generated from spektrafilm 3bb2c2d by Scripts/generate-catalog.py.
// Upstream code: Andrea Volpato, GPLv3. See LICENSE.
import Foundation

extension ParameterDefinition {
    nonisolated static let catalog: [ParameterDefinition] = [
        .number(
            "film_render.density_curve_gamma",
            String(
                localized: "parameter.film_render.density_curve_gamma.title",
                defaultValue: "Film gamma factor"), 1.0, 0.05...3.0, step: 0.05, minimum: 0.05,
            maximum: nil, unit: ""),
        .flag(
            "film_render.grain.active",
            String(localized: "parameter.film_render.grain.active.title", defaultValue: "Active"),
            true),
        .flag(
            "film_render.grain.sublayers_active",
            String(
                localized: "parameter.film_render.grain.sublayers_active.title",
                defaultValue: "Sub-layers active"), true),
        .number(
            "film_render.grain.particle_area_um2",
            String(
                localized: "parameter.film_render.grain.particle_area_um2.title",
                defaultValue: "Particle area"), 0.2, 0.01...10.0, step: 0.01, minimum: 0.01,
            maximum: nil, unit: "µm²"),
        .number(
            "film_render.grain.particle_scale[0]",
            String(
                localized: "parameter.film_render.grain.particle_scale[0].title",
                defaultValue: "Particle area scale · RGB · Red"), 1.6, 0.01...4.800000000000001,
            step: 0.01, minimum: 0.01, maximum: nil, unit: ""),
        .number(
            "film_render.grain.particle_scale[1]",
            String(
                localized: "parameter.film_render.grain.particle_scale[1].title",
                defaultValue: "Particle area scale · RGB · Green"), 1.6, 0.01...4.800000000000001,
            step: 0.01, minimum: 0.01, maximum: nil, unit: ""),
        .number(
            "film_render.grain.particle_scale[2]",
            String(
                localized: "parameter.film_render.grain.particle_scale[2].title",
                defaultValue: "Particle area scale · RGB · Blue"), 3.2, 0.01...9.600000000000001,
            step: 0.01, minimum: 0.01, maximum: nil, unit: ""),
        .number(
            "film_render.grain.particle_scale_layers[0]",
            String(
                localized: "parameter.film_render.grain.particle_scale_layers[0].title",
                defaultValue: "Particle area scale · Layer 1"), 2.0, 0.05...6.0, step: 0.05,
            minimum: 0.05, maximum: nil, unit: ""),
        .number(
            "film_render.grain.particle_scale_layers[1]",
            String(
                localized: "parameter.film_render.grain.particle_scale_layers[1].title",
                defaultValue: "Particle area scale · Layer 2"), 1.0, 0.05...3.0, step: 0.05,
            minimum: 0.05, maximum: nil, unit: ""),
        .number(
            "film_render.grain.particle_scale_layers[2]",
            String(
                localized: "parameter.film_render.grain.particle_scale_layers[2].title",
                defaultValue: "Particle area scale · Layer 3"), 0.5, 0.05...2.0, step: 0.05,
            minimum: 0.05, maximum: nil, unit: ""),
        .number(
            "film_render.grain.density_min[0]",
            String(
                localized: "parameter.film_render.grain.density_min[0].title",
                defaultValue: "Minimum density · RGB · Red"), 0.03, 0.0...2.0, step: 0.01,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.grain.density_min[1]",
            String(
                localized: "parameter.film_render.grain.density_min[1].title",
                defaultValue: "Minimum density · RGB · Green"), 0.03, 0.0...2.0, step: 0.01,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.grain.density_min[2]",
            String(
                localized: "parameter.film_render.grain.density_min[2].title",
                defaultValue: "Minimum density · RGB · Blue"), 0.03, 0.0...2.0, step: 0.01,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.grain.uniformity[0]",
            String(
                localized: "parameter.film_render.grain.uniformity[0].title",
                defaultValue: "Uniformity · RGB · Red"), 0.97, 0.0...1.0, step: 0.01, minimum: 0.0,
            maximum: 1.0, unit: ""),
        .number(
            "film_render.grain.uniformity[1]",
            String(
                localized: "parameter.film_render.grain.uniformity[1].title",
                defaultValue: "Uniformity · RGB · Green"), 0.99, 0.0...1.0, step: 0.01,
            minimum: 0.0, maximum: 1.0, unit: ""),
        .number(
            "film_render.grain.uniformity[2]",
            String(
                localized: "parameter.film_render.grain.uniformity[2].title",
                defaultValue: "Uniformity · RGB · Blue"), 0.97, 0.0...1.0, step: 0.01, minimum: 0.0,
            maximum: 1.0, unit: ""),
        .number(
            "film_render.grain.blur",
            String(localized: "parameter.film_render.grain.blur.title", defaultValue: "Grain blur"),
            0.65, 0.0...2.0, step: 0.05, minimum: 0.0, maximum: nil, unit: "px"),
        .number(
            "film_render.grain.blur_dye_clouds_um",
            String(
                localized: "parameter.film_render.grain.blur_dye_clouds_um.title",
                defaultValue: "Dye cloud blur"), 1.0, 0.0...3.0, step: 0.1, minimum: 0.0,
            maximum: nil, unit: "µm"),
        .number(
            "film_render.grain.micro_structure[0]",
            String(
                localized: "parameter.film_render.grain.micro_structure[0].title",
                defaultValue: "Microstructure · Blur · µm"), 0.2, 0.0...2.0, step: 0.1,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.grain.micro_structure[1]",
            String(
                localized: "parameter.film_render.grain.micro_structure[1].title",
                defaultValue: "Microstructure · Clump size · nm"), 30.0, 0.0...100.0, step: 0.1,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.grain.n_sub_layers",
            String(
                localized: "parameter.film_render.grain.n_sub_layers.title",
                defaultValue: "Sub-layers"), 1.0, 1.0...10.0, step: 1.0, minimum: 1.0,
            maximum: 100.0, unit: ""),
        .flag(
            "film_render.halation.active",
            String(
                localized: "parameter.film_render.halation.active.title", defaultValue: "Active"),
            true),
        .number(
            "film_render.halation.scatter_amount",
            String(
                localized: "parameter.film_render.halation.scatter_amount.title",
                defaultValue: "Scatter amount"), 1.0, 0.0...3.0, step: 0.05, minimum: 0.0,
            maximum: nil, unit: ""),
        .number(
            "film_render.halation.scatter_spatial_scale",
            String(
                localized: "parameter.film_render.halation.scatter_spatial_scale.title",
                defaultValue: "Scatter spatial scale"), 1.0, 0.0...3.0, step: 0.1, minimum: 0.0,
            maximum: nil, unit: ""),
        .number(
            "film_render.halation.halation_amount",
            String(
                localized: "parameter.film_render.halation.halation_amount.title",
                defaultValue: "Halation amount"), 1.0, 0.0...50.0, step: 0.05, minimum: 0.0,
            maximum: nil, unit: "×"),
        .number(
            "film_render.halation.halation_spatial_scale",
            String(
                localized: "parameter.film_render.halation.halation_spatial_scale.title",
                defaultValue: "Halation spatial scale"), 1.0, 0.0...3.0, step: 0.1, minimum: 0.0,
            maximum: nil, unit: ""),
        .number(
            "film_render.halation.scatter_core_um[0]",
            String(
                localized: "parameter.film_render.halation.scatter_core_um[0].title",
                defaultValue: "Scatter core · µm · Red"), 2.2, 0.0...6.6000000000000005, step: 0.5,
            minimum: 0.0, maximum: nil, unit: "µm"),
        .number(
            "film_render.halation.scatter_core_um[1]",
            String(
                localized: "parameter.film_render.halation.scatter_core_um[1].title",
                defaultValue: "Scatter core · µm · Green"), 2.0, 0.0...6.0, step: 0.5, minimum: 0.0,
            maximum: nil, unit: "µm"),
        .number(
            "film_render.halation.scatter_core_um[2]",
            String(
                localized: "parameter.film_render.halation.scatter_core_um[2].title",
                defaultValue: "Scatter core · µm · Blue"), 1.6, 0.0...4.800000000000001, step: 0.5,
            minimum: 0.0, maximum: nil, unit: "µm"),
        .number(
            "film_render.halation.scatter_tail_um[0]",
            String(
                localized: "parameter.film_render.halation.scatter_tail_um[0].title",
                defaultValue: "Scatter tail · µm · Red"), 9.3, 0.0...27.900000000000002, step: 1.0,
            minimum: 0.0, maximum: nil, unit: "µm"),
        .number(
            "film_render.halation.scatter_tail_um[1]",
            String(
                localized: "parameter.film_render.halation.scatter_tail_um[1].title",
                defaultValue: "Scatter tail · µm · Green"), 9.7, 0.0...29.099999999999998, step: 1.0,
            minimum: 0.0, maximum: nil, unit: "µm"),
        .number(
            "film_render.halation.scatter_tail_um[2]",
            String(
                localized: "parameter.film_render.halation.scatter_tail_um[2].title",
                defaultValue: "Scatter tail · µm · Blue"), 9.1, 0.0...27.299999999999997, step: 1.0,
            minimum: 0.0, maximum: nil, unit: "µm"),
        .number(
            "film_render.halation.scatter_tail_weight[0]",
            String(
                localized: "parameter.film_render.halation.scatter_tail_weight[0].title",
                defaultValue: "Scatter tail weight · Red"), 0.78, 0.0...1.0, step: 0.01,
            minimum: 0.0, maximum: 1.0, unit: ""),
        .number(
            "film_render.halation.scatter_tail_weight[1]",
            String(
                localized: "parameter.film_render.halation.scatter_tail_weight[1].title",
                defaultValue: "Scatter tail weight · Green"), 0.65, 0.0...1.0, step: 0.01,
            minimum: 0.0, maximum: 1.0, unit: ""),
        .number(
            "film_render.halation.scatter_tail_weight[2]",
            String(
                localized: "parameter.film_render.halation.scatter_tail_weight[2].title",
                defaultValue: "Scatter tail weight · Blue"), 0.67, 0.0...1.0, step: 0.01,
            minimum: 0.0, maximum: 1.0, unit: ""),
        .number(
            "film_render.halation.boost_ev",
            String(
                localized: "parameter.film_render.halation.boost_ev.title", defaultValue: "Highlight boost · EV"
            ), 0.0, 0.0...2.0, step: 0.5, minimum: 0.0, maximum: nil, unit: "EV"),
        .number(
            "film_render.halation.boost_range",
            String(
                localized: "parameter.film_render.halation.boost_range.title",
                defaultValue: "Highlight boost range"), 0.3, 0.0...1.0, step: 0.05, minimum: 0.0,
            maximum: 1.0, unit: ""),
        .number(
            "film_render.halation.protect_ev",
            String(
                localized: "parameter.film_render.halation.protect_ev.title",
                defaultValue: "Protect threshold · EV"), 4.0, 0.0...12.0, step: 0.5, minimum: 0.0, maximum: nil,
            unit: "EV"),
        .number(
            "film_render.halation.halation_strength[0]",
            String(
                localized: "parameter.film_render.halation.halation_strength[0].title",
                defaultValue: "Halation strength · Red"), 0.05, 0.0...2.0, step: 0.005,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.halation.halation_strength[1]",
            String(
                localized: "parameter.film_render.halation.halation_strength[1].title",
                defaultValue: "Halation strength · Green"), 0.015, 0.0...2.0, step: 0.005,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.halation.halation_strength[2]",
            String(
                localized: "parameter.film_render.halation.halation_strength[2].title",
                defaultValue: "Halation strength · Blue"), 0.0, 0.0...2.0, step: 0.005,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.halation.halation_first_sigma_um[0]",
            String(
                localized: "parameter.film_render.halation.halation_first_sigma_um[0].title",
                defaultValue: "Halation first sigma · µm · Red"), 65.0, 0.0...195.0, step: 1.0,
            minimum: 0.0, maximum: nil, unit: "µm"),
        .number(
            "film_render.halation.halation_first_sigma_um[1]",
            String(
                localized: "parameter.film_render.halation.halation_first_sigma_um[1].title",
                defaultValue: "Halation first sigma · µm · Green"), 65.0, 0.0...195.0, step: 1.0,
            minimum: 0.0, maximum: nil, unit: "µm"),
        .number(
            "film_render.halation.halation_first_sigma_um[2]",
            String(
                localized: "parameter.film_render.halation.halation_first_sigma_um[2].title",
                defaultValue: "Halation first sigma · µm · Blue"), 65.0, 0.0...195.0, step: 1.0,
            minimum: 0.0, maximum: nil, unit: "µm"),
        .number(
            "film_render.halation.halation_n_bounces",
            String(
                localized: "parameter.film_render.halation.halation_n_bounces.title",
                defaultValue: "Halation bounces"), 3.0, 1.0...5.0, step: 1.0, minimum: 1.0,
            maximum: 5.0, unit: ""),
        .number(
            "film_render.halation.halation_bounce_decay",
            String(
                localized: "parameter.film_render.halation.halation_bounce_decay.title",
                defaultValue: "Halation bounce decay"), 0.5, 0.0...1.0, step: 0.05, minimum: 0.0,
            maximum: 1.0, unit: ""),
        .flag(
            "film_render.halation.halation_renormalize",
            String(
                localized: "parameter.film_render.halation.halation_renormalize.title",
                defaultValue: "Halation renormalize"), true),
        .flag(
            "film_render.dir_couplers.active",
            String(
                localized: "parameter.film_render.dir_couplers.active.title", defaultValue: "Active"
            ), true),
        .number(
            "film_render.dir_couplers.amount",
            String(
                localized: "parameter.film_render.dir_couplers.amount.title", defaultValue: "Amount"
            ), 1.0, 0.0...3.0, step: 0.05, minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.dir_couplers.inhibition_samelayer",
            String(
                localized: "parameter.film_render.dir_couplers.inhibition_samelayer.title",
                defaultValue: "Same-layer inhibition"), 1.0, 0.0...3.0, step: 0.05, minimum: 0.0,
            maximum: nil, unit: ""),
        .number(
            "film_render.dir_couplers.inhibition_interlayer",
            String(
                localized: "parameter.film_render.dir_couplers.inhibition_interlayer.title",
                defaultValue: "Interlayer inhibition"), 1.0, 0.0...3.0, step: 0.05, minimum: 0.0,
            maximum: nil, unit: ""),
        .number(
            "film_render.dir_couplers.gamma_samelayer_rgb[0]",
            String(
                localized: "parameter.film_render.dir_couplers.gamma_samelayer_rgb[0].title",
                defaultValue: "Same-layer gamma · Red"), 0.341, 0.0...2.0, step: 0.02,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.dir_couplers.gamma_samelayer_rgb[1]",
            String(
                localized: "parameter.film_render.dir_couplers.gamma_samelayer_rgb[1].title",
                defaultValue: "Same-layer gamma · Green"), 0.324, 0.0...2.0, step: 0.02,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.dir_couplers.gamma_samelayer_rgb[2]",
            String(
                localized: "parameter.film_render.dir_couplers.gamma_samelayer_rgb[2].title",
                defaultValue: "Same-layer gamma · Blue"), 0.273, 0.0...2.0, step: 0.02,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.dir_couplers.gamma_interlayer_r_to_gb[0]",
            String(
                localized: "parameter.film_render.dir_couplers.gamma_interlayer_r_to_gb[0].title",
                defaultValue: "Interlayer gamma · Red→Green"), 0.355, 0.0...2.0, step: 0.02,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.dir_couplers.gamma_interlayer_r_to_gb[1]",
            String(
                localized: "parameter.film_render.dir_couplers.gamma_interlayer_r_to_gb[1].title",
                defaultValue: "Interlayer gamma · Red→Blue"), 0.305, 0.0...2.0, step: 0.02,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.dir_couplers.gamma_interlayer_g_to_rb[0]",
            String(
                localized: "parameter.film_render.dir_couplers.gamma_interlayer_g_to_rb[0].title",
                defaultValue: "Interlayer gamma · Green→Red"), 0.154, 0.0...2.0, step: 0.02,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.dir_couplers.gamma_interlayer_g_to_rb[1]",
            String(
                localized: "parameter.film_render.dir_couplers.gamma_interlayer_g_to_rb[1].title",
                defaultValue: "Interlayer gamma · Green→Blue"), 0.358, 0.0...2.0, step: 0.02,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.dir_couplers.gamma_interlayer_b_to_rg[0]",
            String(
                localized: "parameter.film_render.dir_couplers.gamma_interlayer_b_to_rg[0].title",
                defaultValue: "Interlayer gamma · Blue→Red"), 0.171, 0.0...2.0, step: 0.02,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.dir_couplers.gamma_interlayer_b_to_rg[1]",
            String(
                localized: "parameter.film_render.dir_couplers.gamma_interlayer_b_to_rg[1].title",
                defaultValue: "Interlayer gamma · Blue→Green"), 0.225, 0.0...2.0, step: 0.02,
            minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.dir_couplers.diffusion_size_um",
            String(
                localized: "parameter.film_render.dir_couplers.diffusion_size_um.title",
                defaultValue: "Diffusion size · µm"), 20.0, 0.0...60.0, step: 5.0, minimum: 0.0,
            maximum: nil, unit: "µm"),
        .number(
            "film_render.dir_couplers.diffusion_tail_um",
            String(
                localized: "parameter.film_render.dir_couplers.diffusion_tail_um.title",
                defaultValue: "Diffusion tail · µm"), 200.0, 0.0...600.0, step: 0.01, minimum: 0.0,
            maximum: nil, unit: "µm"),
        .number(
            "film_render.dir_couplers.diffusion_tail_weight",
            String(
                localized: "parameter.film_render.dir_couplers.diffusion_tail_weight.title",
                defaultValue: "Diffusion tail weight"), 0.06, 0.0...1.0, step: 0.01, minimum: 0.0,
            maximum: 1.0, unit: ""),
        .flag(
            "film_render.glare.active",
            String(localized: "parameter.film_render.glare.active.title", defaultValue: "Active"),
            true),
        .number(
            "film_render.glare.percent",
            String(localized: "parameter.film_render.glare.percent.title", defaultValue: "%"),
            0.03, 0.0...2.0, step: 0.01, minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.glare.roughness",
            String(
                localized: "parameter.film_render.glare.roughness.title", defaultValue: "Roughness"),
            0.7, 0.0...2.0999999999999996, step: 0.01, minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "film_render.glare.blur",
            String(localized: "parameter.film_render.glare.blur.title", defaultValue: "Glare blur"),
            0.5, 0.0...2.0, step: 0.01, minimum: 0.0, maximum: nil, unit: ""),
        .flag(
            "print_render.glare.active",
            String(localized: "parameter.print_render.glare.active.title", defaultValue: "Active"),
            true),
        .number(
            "print_render.glare.percent",
            String(
                localized: "parameter.print_render.glare.percent.title", defaultValue: "%"),
            0.03, 0.0...1.0, step: 0.01, minimum: 0.0, maximum: 1.0, unit: ""),
        .number(
            "print_render.glare.roughness",
            String(
                localized: "parameter.print_render.glare.roughness.title", defaultValue: "Roughness"
            ), 0.7, 0.0...1.0, step: 0.05, minimum: 0.0, maximum: 1.0, unit: ""),
        .number(
            "print_render.glare.blur",
            String(
                localized: "parameter.print_render.glare.blur.title", defaultValue: "Glare blur"),
            0.5, 0.0...2.0, step: 0.1, minimum: 0.0, maximum: nil, unit: ""),
        .flag(
            "print_render.density_curves_morph.active",
            String(
                localized: "parameter.print_render.density_curves_morph.active.title",
                defaultValue: "Active"), false),
        .number(
            "print_render.density_curves_morph.gamma_factor",
            String(
                localized: "parameter.print_render.density_curves_morph.gamma_factor.title",
                defaultValue: "Gamma factor"), 1.0, 0.5...2.0, step: 0.05, minimum: 0.5,
            maximum: 2.0, unit: ""),
        .number(
            "print_render.density_curves_morph.gamma_factor_fast",
            String(
                localized: "parameter.print_render.density_curves_morph.gamma_factor_fast.title",
                defaultValue: "Gamma factor · Fast layer"), 1.0, 0.5...2.0, step: 0.05, minimum: 0.5,
            maximum: 2.0, unit: ""),
        .number(
            "print_render.density_curves_morph.gamma_factor_slow",
            String(
                localized: "parameter.print_render.density_curves_morph.gamma_factor_slow.title",
                defaultValue: "Gamma factor · Slow layers"), 1.0, 0.5...2.0, step: 0.05, minimum: 0.5,
            maximum: 2.0, unit: ""),
        .number(
            "print_render.density_curves_morph.gamma_factor_red",
            String(
                localized: "parameter.print_render.density_curves_morph.gamma_factor_red.title",
                defaultValue: "Gamma factor · Red"), 1.0, 0.5...2.0, step: 0.02, minimum: 0.5,
            maximum: 2.0, unit: ""),
        .number(
            "print_render.density_curves_morph.gamma_factor_green",
            String(
                localized: "parameter.print_render.density_curves_morph.gamma_factor_green.title",
                defaultValue: "Gamma factor · Green"), 1.0, 0.5...2.0, step: 0.02, minimum: 0.5,
            maximum: 2.0, unit: ""),
        .number(
            "print_render.density_curves_morph.gamma_factor_blue",
            String(
                localized: "parameter.print_render.density_curves_morph.gamma_factor_blue.title",
                defaultValue: "Gamma factor · Blue"), 1.0, 0.5...2.0, step: 0.02, minimum: 0.5,
            maximum: 2.0, unit: ""),
        .number(
            "print_render.density_curves_morph.developer_exhaustion",
            String(
                localized: "parameter.print_render.density_curves_morph.developer_exhaustion.title",
                defaultValue: "Developer exhaustion"), 0.0, 0.0...1.0, step: 0.02, minimum: 0.0,
            maximum: 1.0, unit: ""),
        .number(
            "camera.exposure_compensation_ev",
            String(
                localized: "parameter.camera.exposure_compensation_ev.title",
                defaultValue: "Film exposure"), 0.0, -5.0...5.0, step: 0.25, minimum: -100.0,
            maximum: 100.0, unit: "EV"),
        .flag(
            "camera.auto_exposure",
            String(
                localized: "parameter.camera.auto_exposure.title",
                defaultValue: "Auto film exposure"), true),
        .choice(
            "camera.auto_exposure_method",
            String(
                localized: "parameter.camera.auto_exposure_method.title",
                defaultValue: "Auto exposure method"), "center_weighted",
            [
                "center_weighted", "matrix", "multi_zone", "partial", "highlight_weighted",
                "median", "average",
            ]),
        .number(
            "camera.lens_blur_um",
            String(localized: "parameter.camera.lens_blur_um.title", defaultValue: "Lens blur · µm"),
            0.0, 0.0...2.0, step: 0.05, minimum: 0.0, maximum: nil, unit: "µm"),
        .number(
            "camera.film_format_mm",
            String(
                localized: "parameter.camera.film_format_mm.title",
                defaultValue: "Film long edge · mm"), 35.0, 8.0...120.0, step: 1.0, minimum: 8.0,
            maximum: 120.0, unit: ""),
        .number(
            "camera.filter_uv[0]",
            String(
                localized: "parameter.camera.filter_uv[0].title",
                defaultValue: "UV filter · Strength"), 0.0, 0.0...1.0, step: 0.01, minimum: 0.0,
            maximum: 1.0, unit: ""),
        .number(
            "camera.filter_uv[1]",
            String(
                localized: "parameter.camera.filter_uv[1].title",
                defaultValue: "UV filter · Cutoff · nm"), 410.0, 0.0...1230.0, step: 0.01,
            minimum: nil, maximum: nil, unit: ""),
        .number(
            "camera.filter_uv[2]",
            String(
                localized: "parameter.camera.filter_uv[2].title",
                defaultValue: "UV filter · Transition · nm"), 8.0, 0.01...24.0, step: 0.01,
            minimum: 0.01, maximum: nil, unit: ""),
        .number(
            "camera.filter_ir[0]",
            String(
                localized: "parameter.camera.filter_ir[0].title",
                defaultValue: "IR filter · Strength"), 0.0, 0.0...1.0, step: 0.01, minimum: 0.0,
            maximum: 1.0, unit: ""),
        .number(
            "camera.filter_ir[1]",
            String(
                localized: "parameter.camera.filter_ir[1].title",
                defaultValue: "IR filter · Cutoff · nm"), 675.0, 0.0...2025.0, step: 0.01,
            minimum: nil, maximum: nil, unit: ""),
        .number(
            "camera.filter_ir[2]",
            String(
                localized: "parameter.camera.filter_ir[2].title",
                defaultValue: "IR filter · Transition · nm"), 15.0, 0.01...45.0, step: 0.01,
            minimum: 0.01, maximum: nil, unit: ""),
        .flag(
            "camera.diffusion_filter.active",
            String(
                localized: "parameter.camera.diffusion_filter.active.title", defaultValue: "Active"),
            false),
        .choice(
            "camera.diffusion_filter.filter_family",
            String(
                localized: "parameter.camera.diffusion_filter.filter_family.title",
                defaultValue: "Filter family"), "black_pro_mist",
            ["glimmerglass", "black_pro_mist", "pro_mist", "cinebloom"]),
        .number(
            "camera.diffusion_filter.strength",
            String(
                localized: "parameter.camera.diffusion_filter.strength.title",
                defaultValue: "Strength"), 0.5, 0.0...2.0, step: 0.125, minimum: 0.0, maximum: 2.0,
            unit: ""),
        .number(
            "camera.diffusion_filter.spatial_scale",
            String(
                localized: "parameter.camera.diffusion_filter.spatial_scale.title",
                defaultValue: "Spatial scale"), 1.0, 0.0...3.0, step: 0.1, minimum: 0.0,
            maximum: nil, unit: ""),
        .number(
            "camera.diffusion_filter.halo_warmth",
            String(
                localized: "parameter.camera.diffusion_filter.halo_warmth.title",
                defaultValue: "Halo warmth"), 0.0, -1.5...1.5, step: 0.05, minimum: -1.5,
            maximum: 1.5, unit: ""),
        .number(
            "camera.diffusion_filter.core_intensity",
            String(
                localized: "parameter.camera.diffusion_filter.core_intensity.title",
                defaultValue: "Core intensity"), 1.0, 0.0...4.0, step: 0.05, minimum: 0.0,
            maximum: 4.0, unit: ""),
        .number(
            "camera.diffusion_filter.core_size",
            String(
                localized: "parameter.camera.diffusion_filter.core_size.title",
                defaultValue: "Core size"), 1.0, 0.1...4.0, step: 0.05, minimum: 0.1, maximum: 4.0,
            unit: ""),
        .number(
            "camera.diffusion_filter.halo_intensity",
            String(
                localized: "parameter.camera.diffusion_filter.halo_intensity.title",
                defaultValue: "Halo intensity"), 1.0, 0.0...4.0, step: 0.05, minimum: 0.0,
            maximum: 4.0, unit: ""),
        .number(
            "camera.diffusion_filter.halo_size",
            String(
                localized: "parameter.camera.diffusion_filter.halo_size.title",
                defaultValue: "Halo size"), 1.0, 0.1...4.0, step: 0.05, minimum: 0.1, maximum: 4.0,
            unit: ""),
        .number(
            "camera.diffusion_filter.bloom_intensity",
            String(
                localized: "parameter.camera.diffusion_filter.bloom_intensity.title",
                defaultValue: "Bloom intensity"), 1.0, 0.0...4.0, step: 0.05, minimum: 0.0,
            maximum: 4.0, unit: ""),
        .number(
            "camera.diffusion_filter.bloom_size",
            String(
                localized: "parameter.camera.diffusion_filter.bloom_size.title",
                defaultValue: "Bloom size"), 1.0, 0.1...4.0, step: 0.05, minimum: 0.1, maximum: 4.0,
            unit: ""),
        .choice(
            "enlarger.illuminant",
            String(
                localized: "parameter.enlarger.illuminant.title", defaultValue: "Print illuminant"),
            "TH-KG3", ["TH-KG3"]),
        .number(
            "enlarger.print_exposure",
            String(
                localized: "parameter.enlarger.print_exposure.title", defaultValue: "Print exposure"
            ), 1.0, 0.0...3.0, step: 0.02, minimum: 0.0, maximum: nil, unit: ""),
        .flag(
            "enlarger.print_exposure_compensation",
            String(
                localized: "parameter.enlarger.print_exposure_compensation.title",
                defaultValue: "Match print brightness"), true),
        .flag(
            "enlarger.normalize_print_exposure",
            String(
                localized: "parameter.enlarger.normalize_print_exposure.title",
                defaultValue: "Calibrate middle gray"), true),
        .number(
            "enlarger.y_filter_shift",
            String(
                localized: "parameter.enlarger.y_filter_shift.title", defaultValue: "Yellow balance"
            ), 0.0, -100.0...100.0, step: 1.0, minimum: -200.0, maximum: nil, unit: "CC"),
        .number(
            "enlarger.m_filter_shift",
            String(
                localized: "parameter.enlarger.m_filter_shift.title",
                defaultValue: "Magenta balance"), 0.0, -100.0...100.0, step: 1.0, minimum: -200.0,
            maximum: nil, unit: "CC"),
        .number(
            "enlarger.y_filter_neutral",
            String(
                localized: "parameter.enlarger.y_filter_neutral.title",
                defaultValue: "Yellow filter neutral"), 55.0, 0.0...165.0, step: 0.01, minimum: 0.0,
            maximum: nil, unit: ""),
        .number(
            "enlarger.m_filter_neutral",
            String(
                localized: "parameter.enlarger.m_filter_neutral.title",
                defaultValue: "Magenta filter neutral"), 65.0, 0.0...195.0, step: 0.01, minimum: 0.0,
            maximum: nil, unit: ""),
        .number(
            "enlarger.c_filter_neutral",
            String(
                localized: "parameter.enlarger.c_filter_neutral.title",
                defaultValue: "Cyan filter neutral"), 0.0, 0.0...2.0, step: 0.01, minimum: 0.0,
            maximum: nil, unit: ""),
        .number(
            "enlarger.lens_blur",
            String(localized: "parameter.enlarger.lens_blur.title", defaultValue: "Lens blur"), 0.0,
            0.0...2.0, step: 0.01, minimum: 0.0, maximum: nil, unit: ""),
        .flag(
            "enlarger.diffusion_filter.active",
            String(
                localized: "parameter.enlarger.diffusion_filter.active.title",
                defaultValue: "Active"), false),
        .choice(
            "enlarger.diffusion_filter.filter_family",
            String(
                localized: "parameter.enlarger.diffusion_filter.filter_family.title",
                defaultValue: "Filter family"), "black_pro_mist",
            ["glimmerglass", "black_pro_mist", "pro_mist", "cinebloom"]),
        .number(
            "enlarger.diffusion_filter.strength",
            String(
                localized: "parameter.enlarger.diffusion_filter.strength.title",
                defaultValue: "Strength"), 0.5, 0.0...2.0, step: 0.125, minimum: 0.0, maximum: 2.0,
            unit: ""),
        .number(
            "enlarger.diffusion_filter.spatial_scale",
            String(
                localized: "parameter.enlarger.diffusion_filter.spatial_scale.title",
                defaultValue: "Spatial scale"), 1.0, 0.0...3.0, step: 0.1, minimum: 0.0,
            maximum: nil, unit: ""),
        .number(
            "enlarger.diffusion_filter.halo_warmth",
            String(
                localized: "parameter.enlarger.diffusion_filter.halo_warmth.title",
                defaultValue: "Halo warmth"), 0.0, -1.5...1.5, step: 0.05, minimum: -1.5,
            maximum: 1.5, unit: ""),
        .number(
            "enlarger.diffusion_filter.core_intensity",
            String(
                localized: "parameter.enlarger.diffusion_filter.core_intensity.title",
                defaultValue: "Core intensity"), 1.0, 0.0...4.0, step: 0.05, minimum: 0.0,
            maximum: 4.0, unit: ""),
        .number(
            "enlarger.diffusion_filter.core_size",
            String(
                localized: "parameter.enlarger.diffusion_filter.core_size.title",
                defaultValue: "Core size"), 1.0, 0.1...4.0, step: 0.05, minimum: 0.1, maximum: 4.0,
            unit: ""),
        .number(
            "enlarger.diffusion_filter.halo_intensity",
            String(
                localized: "parameter.enlarger.diffusion_filter.halo_intensity.title",
                defaultValue: "Halo intensity"), 1.0, 0.0...4.0, step: 0.05, minimum: 0.0,
            maximum: 4.0, unit: ""),
        .number(
            "enlarger.diffusion_filter.halo_size",
            String(
                localized: "parameter.enlarger.diffusion_filter.halo_size.title",
                defaultValue: "Halo size"), 1.0, 0.1...4.0, step: 0.05, minimum: 0.1, maximum: 4.0,
            unit: ""),
        .number(
            "enlarger.diffusion_filter.bloom_intensity",
            String(
                localized: "parameter.enlarger.diffusion_filter.bloom_intensity.title",
                defaultValue: "Bloom intensity"), 1.0, 0.0...4.0, step: 0.05, minimum: 0.0,
            maximum: 4.0, unit: ""),
        .number(
            "enlarger.diffusion_filter.bloom_size",
            String(
                localized: "parameter.enlarger.diffusion_filter.bloom_size.title",
                defaultValue: "Bloom size"), 1.0, 0.1...4.0, step: 0.05, minimum: 0.1, maximum: 4.0,
            unit: ""),
        .number(
            "enlarger.preflash_exposure",
            String(
                localized: "parameter.enlarger.preflash_exposure.title", defaultValue: "Preflash exposure"),
            0.0, 0.0...2.0, step: 0.005, minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "enlarger.preflash_y_filter_shift",
            String(
                localized: "parameter.enlarger.preflash_y_filter_shift.title",
                defaultValue: "Preflash yellow shift"), 0.0, -100.0...100.0, step: 1.0, minimum: nil,
            maximum: nil, unit: "CC"),
        .number(
            "enlarger.preflash_m_filter_shift",
            String(
                localized: "parameter.enlarger.preflash_m_filter_shift.title",
                defaultValue: "Preflash magenta shift"), 0.0, -100.0...100.0, step: 1.0, minimum: nil,
            maximum: nil, unit: "CC"),
        .number(
            "scanner.lens_blur",
            String(localized: "parameter.scanner.lens_blur.title", defaultValue: "Lens blur"), 0.0,
            0.0...2.0, step: 0.05, minimum: 0.0, maximum: nil, unit: ""),
        .flag(
            "scanner.white_correction",
            String(
                localized: "parameter.scanner.white_correction.title",
                defaultValue: "White correction"), false),
        .flag(
            "scanner.black_correction",
            String(
                localized: "parameter.scanner.black_correction.title",
                defaultValue: "Black correction"), false),
        .number(
            "scanner.white_level",
            String(localized: "parameter.scanner.white_level.title", defaultValue: "White level"),
            0.98, 0.0...1.0, step: 0.005, minimum: 0.0, maximum: 1.0, unit: ""),
        .number(
            "scanner.black_level",
            String(localized: "parameter.scanner.black_level.title", defaultValue: "Black level"),
            0.01, 0.0...1.0, step: 0.005, minimum: 0.0, maximum: 1.0, unit: ""),
        .number(
            "scanner.unsharp_mask[0]",
            String(
                localized: "parameter.scanner.unsharp_mask[0].title",
                defaultValue: "Unsharp mask · Radius · px"), 0.7, 0.0...2.0999999999999996,
            step: 0.05, minimum: 0.0, maximum: nil, unit: ""),
        .number(
            "scanner.unsharp_mask[1]",
            String(
                localized: "parameter.scanner.unsharp_mask[1].title",
                defaultValue: "Unsharp mask · Amount"), 0.7, 0.0...2.0999999999999996, step: 0.05,
            minimum: 0.0, maximum: nil, unit: ""),
    ]
}
