import SwiftUI

/// RAW adjustments precede Develop. Whole-photo monochrome follows the selected look.
struct AdjustPanel: View {
    enum Section: String, CaseIterable {
        case exposure, liftGain, color
        var title: String {
            switch self {
            case .exposure:
                String(localized: "adjust.exposure_contrast", defaultValue: "Exposure/Contrast")
            case .liftGain: String(localized: "adjust.lift_gain", defaultValue: "Lift/Gain")
            case .color: String(localized: "adjust.color", defaultValue: "Color")
            }
        }
    }
    let session: EditorSession
    var section: Section = .exposure
    @State private var extendedBalance = false
    @State private var extendedLiftGain = false
    private var wideLiftGain: Bool {
        extendedLiftGain || abs(session.recipe.tone.highlights) > 2
            || abs(session.recipe.tone.shadows) > 2
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch section {
            case .exposure:
                NumericControl(
                    title: String(localized: "adjust.exposure", defaultValue: "Exposure"),
                    value: Binding(
                        get: { session.recipe.tone.exposureEV },
                        set: { value in
                            session.update(key: "tone.exposure") { $0.tone.exposureEV = value }
                        }),
                    range: -5...5, step: 0.05, minimum: -10, maximum: 10, unit: "EV",
                    identifier: "tone.exposure",
                    onEditingChanged: { session.setInteraction(key: "tone.exposure", active: $0) })
                field("camera.exposure_compensation_ev").disabled(!session.recipe.look.enabled || session.recipe.look.mode == .lut)
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 16) {
                        field("camera.auto_exposure")
                        if session.recipe.flag("camera.auto_exposure") {
                            field("camera.auto_exposure_method")
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            NumericControl(
                                title: String(
                                    localized: "adjust.print_exposure",
                                    defaultValue: "Print exposure"),
                                value: session.binding(
                                    \.printExposureEV, key: "enlarger.print_exposure"),
                                range: -3...3, step: 0.05, minimum: -10, maximum: 10, unit: "EV",
                                identifier: "enlarger.print_exposure",
                                onEditingChanged: {
                                    session.setInteraction(
                                        key: "enlarger.print_exposure", active: $0)
                                })
                            DisclosureGroup(
                                String(localized: "adjust.calibration", defaultValue: "Calibration")
                            ) {
                                NumericControl(
                                    title: String(
                                        localized: "adjust.input_exposure",
                                        defaultValue: "Input exposure"),
                                    value: sourceBinding(\.exposureEV, key: "source.exposure"),
                                    range: -5...5,
                                    step: 0.05, minimum: -10, maximum: 10, unit: "EV",
                                    identifier: "source.exposure")
                                field("enlarger.normalize_print_exposure").padding(.top, 8)
                            }
                        }.disabled(!session.recipe.look.enabled || session.recipe.bypassesPrint || session.recipe.look.mode == .lut)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                } label: {
                    Text(
                        String(
                            localized: "adjust.print_exposure_metering",
                            defaultValue: "Print exposure & metering")
                    ).foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier(
                            "adjust.exposureStages")
                }
                .disabled(!session.recipe.look.enabled || session.recipe.look.mode == .lut)
                Divider()
                toneControl(
                    String(localized: "adjust.s_curve", defaultValue: "S-curve"), path: \.contrast,
                    range: -0.35...0.35, defaultValue: 0,
                    id: "contrast")
                toneControl(
                    String(localized: "adjust.pivot", defaultValue: "Pivot"), path: \.pivot,
                    range: 0...1, defaultValue: 0.35, id: "pivot")
            case .liftGain:
                HStack {
                    Text(Section.liftGain.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    ControlRangeButton(
                        title: wideLiftGain ? "±5" : "±2",
                        label: String(
                            localized: "adjust.change_lift_gain_range",
                            defaultValue: "Change highlights and shadows range"),
                        identifier: "adjust.liftGainRange"
                    ) { extendedLiftGain = !wideLiftGain }
                    .disabled(
                        abs(session.recipe.tone.highlights) > 2
                            || abs(session.recipe.tone.shadows) > 2)
                }
                toneControl(
                    String(localized: "adjust.highlights", defaultValue: "Highlights"),
                    path: \.highlights, range: wideLiftGain ? -5...5 : -2...2, defaultValue: 0,
                    id: "highlights")
                toneControl(
                    String(localized: "adjust.shadows", defaultValue: "Shadows"), path: \.shadows,
                    range: wideLiftGain ? -5...5 : -2...2, defaultValue: 0, id: "shadows")
            case .color:
                if let temperature = session.recipe.temperature {
                    NumericControl(
                        title: String(localized: "adjust.temperature", defaultValue: "Temperature"),
                        value: Binding(
                            get: { session.recipe.temperature ?? temperature },
                            set: { value in
                                session.update(key: "temperature") { $0.temperature = value }
                            }),
                        range: 2500...8000, step: 25, minimum: 1000, maximum: 50000, unit: "K",
                        identifier: "source.temperature",
                        defaultValue: session.photo.rawTemperature ?? temperature,
                        onEditingChanged: { session.setInteraction(key: "temperature", active: $0) }
                    )
                } else {
                    NumericControl(
                        title: String(localized: "adjust.warmth", defaultValue: "Warmth"),
                        value: sourceBinding(\.warmth, key: "source.warmth"),
                        range: -50...50, step: 1, minimum: -100, maximum: 100,
                        identifier: "source.warmth",
                        onEditingChanged: {
                            session.setInteraction(key: "source.warmth", active: $0)
                        })
                }
                NumericControl(
                    title: String(localized: "adjust.tint", defaultValue: "Tint"),
                    value: sourceBinding(\.tint, key: "source.tint"),
                    range: -50...50, step: 1, minimum: -100, maximum: 100,
                    identifier: "source.tint",
                    onEditingChanged: { session.setInteraction(key: "source.tint", active: $0) })
                NumericControl(
                    title: String(localized: "adjust.saturation", defaultValue: "Saturation"),
                    value: Binding(
                        get: { session.recipe.source.saturation * 100 },
                        set: { value in
                            session.update(key: "source.saturation") {
                                $0.source.saturation = value / 100
                            }
                        }),
                    range: 0...200, step: 1, minimum: 0, maximum: 200, unit: "%",
                    identifier: "source.saturation", defaultValue: 100,
                    onEditingChanged: {
                        session.setInteraction(key: "source.saturation", active: $0)
                    })
                AdaptiveToggle(
                    String(localized: "adjust.black_white", defaultValue: "Black & White"),
                    isOn: Binding(
                        get: { session.recipe.tone.monochrome },
                        set: { value in
                            session.update(key: "tone.monochrome") { $0.tone.monochrome = value }
                        })
                )
                .accessibilityIdentifier("tone.monochrome")
                printBalance
                DisclosureGroup(
                    String(localized: "adjust.dye_couplers", defaultValue: "Dye couplers")
                ) {
                    EffectSection(
                        title: String(
                            localized: "adjust.dye_couplers", defaultValue: "Dye couplers"),
                        prefix: "film_render.dir_couplers",
                        prominent: ["amount"],
                        session: session
                    ).padding(.top, 8)
                }.disabled(!session.recipe.look.enabled || session.recipe.look.mode == .lut)
                DisclosureGroup(String(localized: "adjust.details", defaultValue: "Details")) {
                    VStack(alignment: .leading, spacing: 12) {
                        ParameterFields(session: session, prefix: "scanner")
                        ParameterFields(
                            session: session, prefix: "enlarger",
                            names: [
                                "preflash_exposure", "preflash_y_filter_shift",
                                "preflash_m_filter_shift",
                            ]
                        ).disabled(session.recipe.bypassesPrint)
                        ParameterFields(
                            session: session, prefix: "film_render",
                            names: ["density_curve_gamma"])
                        ParameterFields(
                            session: session, prefix: "camera",
                            names: ["lens_blur_um", "film_format_mm", "filter_uv", "filter_ir"])
                    }.padding(.top, 8)
                }
                .disabled(!session.recipe.look.enabled || session.recipe.look.mode == .lut)

            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var printBalance: some View {
        DisclosureGroup(String(localized: "adjust.print_balance", defaultValue: "Print balance")) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(String(localized: "adjust.color_balance", defaultValue: "Color balance"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    ControlRangeButton(
                        title: extendedBalance
                            ? String(localized: "adjust.100_cc", defaultValue: "±100 CC")
                            : "±35 CC",
                        label: String(
                            localized: "adjust.change_color_balance_range",
                            defaultValue: "Change color balance range"),
                        identifier: "adjust.balanceRange"
                    ) { extendedBalance.toggle() }
                }
                balance(
                    "enlarger.y_filter_shift",
                    title: String(
                        localized: "adjust.yellow_balance", defaultValue: "Yellow balance"))
                balance(
                    "enlarger.m_filter_shift",
                    title: String(
                        localized: "adjust.magenta_balance", defaultValue: "Magenta balance"))
                DisclosureGroup(
                    String(localized: "adjust.print_contrast", defaultValue: "Print contrast")
                ) {
                    EffectSection(
                        title: String(
                            localized: "adjust.print_chemistry", defaultValue: "Print chemistry"),
                        prefix: "print_render.density_curves_morph",
                        prominent: ["gamma_factor"], session: session, printOnly: true
                    ).padding(.top, 12)
                }
            }.disabled(!session.recipe.look.enabled || session.recipe.bypassesPrint || session.recipe.look.mode == .lut)
            if session.recipe.bypassesPrint {
                Text(
                    String(
                        localized: "adjust.direct_scan_skips_print_controls",
                        defaultValue: "Direct scan skips print controls.")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(!session.recipe.look.enabled || session.recipe.bypassesPrint || session.recipe.look.mode == .lut)
    }
    private func toneControl(
        _ title: String, path: WritableKeyPath<EditRecipe.Tone, Double>, range: ClosedRange<Double>,
        defaultValue: Double, id: String
    ) -> some View {
        NumericControl(
            title: title,
            value: Binding(
                get: { session.recipe.tone[keyPath: path] - (id == "contrast" ? 1 : 0) },
                set: { value in
                    session.update(key: "tone." + id) {
                        $0.tone.algorithm = 5
                        $0.tone[keyPath: path] =
                            id == "contrast" ? min(max(value, -0.35), 0.35) + 1 : value
                    }
                }),
            range: range, step: 0.01,
            minimum: id == "highlights" || id == "shadows" ? -5 : range.lowerBound,
            maximum: id == "highlights" || id == "shadows" ? 5 : range.upperBound,
            identifier: "tone." + id, defaultValue: defaultValue,
            onEditingChanged: { session.setInteraction(key: "tone." + id, active: $0) })
    }
    private func sourceBinding(_ path: WritableKeyPath<EditRecipe.Source, Double>, key: String)
        -> Binding<
            Double
        >
    {
        Binding(
            get: { session.recipe.source[keyPath: path] },
            set: { value in session.update(key: key) { $0.source[keyPath: path] = value } })
    }
    private func balance(_ path: String, title: String) -> some View {
        NumericControl(
            title: title,
            value: Binding(
                get: { session.recipe.number(path) },
                set: { value in
                    session.update(key: path) { $0.numbers[path] = value }
                    if abs(value) > 35 { extendedBalance = true }
                }),
            range: extendedBalance ? -100...100 : -35...35, step: 0.25, minimum: -200, maximum: 200,
            unit: "CC", identifier: path,
            onEditingChanged: { session.setInteraction(key: path, active: $0) })
    }
    @ViewBuilder private func field(_ path: String) -> some View {
        if let definition = ParameterDefinition.byPath[path] {
            ParameterControl(definition: definition, session: session)
        }
    }
}
