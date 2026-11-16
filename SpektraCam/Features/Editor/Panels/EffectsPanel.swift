import SwiftUI

struct EffectsPanel: View {
    enum Section: String, CaseIterable {
        case grain, halation, diffusion
        var title: String {
            switch self {
            case .grain: String(localized: "effects.grain", defaultValue: "Grain")
            case .halation: String(localized: "effects.halation", defaultValue: "Halation")
            case .diffusion: String(localized: "effects.diffusion", defaultValue: "Diffusion")
            }
        }
    }
    let session: EditorSession
    var section: Section = .grain
    @State private var confirmStockGrain = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch section {
            case .grain:
                EffectSection(
                    title: String(localized: "effects.grain", defaultValue: "Grain"),
                    prefix: "film_render.grain",
                    prominent: ["particle_area_um2", "blur"], session: session, showsDetails: false)
                AdaptiveToggle(
                    String(localized: "effects.b_w_grain", defaultValue: "B&W Grain"),
                    isOn: session.binding(\.monochromeGrain, key: "grain.monochrome")
                )
                .disabled(!session.recipe.flag("film_render.grain.active"))
                .accessibilityIdentifier("grain.monochrome")
                Button(
                    String(localized: "effects.use_stock_grain", defaultValue: "Use Stock Grain"),
                    systemImage: "arrow.counterclockwise"
                ) { confirmStockGrain = true }
                .buttonStyle(.glass).controlSize(.small).accessibilityIdentifier(
                    "grain.stockDefaults"
                )
                .confirmationDialog(
                    String(
                        localized: "effects.use_stock_grain_confirm",
                        defaultValue: "Use stock grain settings?"), isPresented: $confirmStockGrain,
                    titleVisibility: .visible
                ) {
                    Button(
                        String(
                            localized: "effects.use_stock_grain", defaultValue: "Use Stock Grain"),
                        action: session.resetGrain)
                }
                EffectDetails(
                    prefix: "film_render.grain", prominent: ["particle_area_um2", "blur"],
                    session: session)
            case .halation:
                EffectSection(
                    title: String(
                        localized: "effects.halation_scatter", defaultValue: "Halation & scatter"),
                    prefix: "film_render.halation",
                    prominent: ["halation_amount", "scatter_amount"], session: session)
                DisclosureGroup(
                    String(localized: "effects.print_glare", defaultValue: "Print glare")
                ) {
                    EffectSection(
                        title: String(
                            localized: "effects.print_glare", defaultValue: "Print glare"),
                        prefix: "print_render.glare",
                        prominent: ["percent"], session: session, printOnly: true
                    ).padding(.top, 8)
                }
                .disabled(session.recipe.look.mode == .lut)
            case .diffusion:
                EffectSection(
                    title: String(
                        localized: "effects.camera_diffusion", defaultValue: "Camera diffusion"),
                    prefix: "camera.diffusion_filter",
                    prominent: ["filter_family", "strength"], session: session)
                EffectSection(
                    title: String(
                        localized: "effects.enlarger_diffusion", defaultValue: "Enlarger diffusion"),
                    prefix: "enlarger.diffusion_filter",
                    prominent: ["filter_family", "strength"], session: session, printOnly: true)

            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
