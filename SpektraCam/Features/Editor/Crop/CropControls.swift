import SwiftUI

/// Contextual crop controls sit above the persistent system toolbar.
struct CropControls: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var crop: CropSelection
    @Binding var geometry: ImageGeometry
    let imageAspect: CGFloat
    var filmGate: FilmEdgeLayout? = nil
    let rotateLeft: () -> Void
    let flipHorizontal: () -> Void
    let flipVertical: () -> Void
    let reset: () -> Void
    let done: () -> Void
    let canReset: Bool
    var onStraightenEditingChanged: (Bool) -> Void = { _ in }

    private let common: [CropAspect] = [
        .free, .original, .square, .fourThree, .threeTwo, .sixteenNine, .cinemaFlat, .cinemaScope,
    ]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if typeSize.isAccessibilitySize {
                    ScrollView { controls }
                        .frame(height: 280)
                        .clipped()
                } else {
                    controls
                }
            }
            HStack {
                Button(String(localized: "editor.reset", defaultValue: "Reset"), action: reset)
                    .buttonStyle(.glass).disabled(!canReset)
                    .accessibilityLabel(String(localized: "editor.reset_crop", defaultValue: "Reset Crop"))
                    .accessibilityIdentifier("crop.reset")
                Spacer()
                Button(String(localized: "common.done", defaultValue: "Done"),
                    systemImage: "checkmark", action: done)
                    .buttonStyle(.glassProminent).foregroundStyle(.white)
                    .accessibilityIdentifier("crop.done")
            }
            .controlSize(.regular).frame(minHeight: 44)
            .padding(.horizontal, 16).padding(.bottom, 8)
        }.background(.background)
            .onChange(of: geometry.straightenDegrees) { _, angle in
                if angle == 0 {
                    geometry.framingX = 0
                    geometry.framingY = 0
                }
            }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if let filmGate {
                LabeledContent(String(localized: "darkroom.edge.fixed_gate", defaultValue: "Fixed film gate"),
                    value: filmGate.gateTitle(portrait: crop.orientation == .portrait))
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("crop.filmGate")
            } else {
                aspectControls
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    transformButtons
                    Spacer()
                    if filmGate?.format != .roll120 { orientationButtons }
                }
                VStack(spacing: 8) {
                    HStack { transformButtons }
                    if filmGate?.format != .roll120 { HStack { orientationButtons } }
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)

            straightenControls
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var aspectControls: some View {
        HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(common) { aspect in
                            Button(aspect.title) {
                                crop.setAspect(aspect, imageAspect: imageAspect)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(crop.aspect == aspect ? Color.accentColor : .secondary)
                            .accessibilityAddTraits(crop.aspect == aspect ? .isSelected : [])
                            .accessibilityIdentifier("crop.ratio.\(aspect.id)")
                        }
                    }
                }.scrollIndicators(.hidden)
                Menu(String(localized: "crop.more", defaultValue: "More"), systemImage: "ellipsis")
                {
                    ForEach(
                        CropAspect.allCases.filter {
                            !common.contains($0)
                                && ![.nineSixteen, .twoThree, .threeFour].contains($0)
                        }
                    ) { aspect in
                        Button(aspect.title) { crop.setAspect(aspect, imageAspect: imageAspect) }
                    }
                }
                .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                .accessibilityLabel(
                    String(localized: "crop.more_aspect_ratios", defaultValue: "More Aspect Ratios")
                )
                .accessibilityIdentifier("crop.moreRatios")
        }
    }
    private var straightenControls: some View {
        VStack(spacing: 2) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text(String(localized: "crop.straighten", defaultValue: "Straighten"))
                        Spacer()
                        straightenValue
                    }
                    VStack(alignment: .leading) {
                        Text(String(localized: "crop.straighten", defaultValue: "Straighten"))
                        straightenValue
                    }
                }.font(.subheadline)
                DefaultSlider(
                    value: $geometry.straightenDegrees, range: -45...45, step: 0.1,
                    title: String(localized: "crop.straighten", defaultValue: "Straighten"),
                    identifier: "crop.straighten",
                    onEditingChanged: onStraightenEditingChanged
                )
                .accessibilityLabel(
                    String(localized: "crop.straighten", defaultValue: "Straighten")
                )
                .accessibilityValue(
                    String(
                        localized: "crop.straighten_degrees",
                        defaultValue:
                            "\(geometry.straightenDegrees.formatted(.number.precision(.fractionLength(1)))) degrees"
                    )
                )
                .accessibilityIdentifier("crop.straighten")
        }
    }

    private var transformButtons: some View {
        Group {
            transform(
                String(localized: "crop.rotate_left", defaultValue: "Rotate Left"),
                symbol: "rotate.left", action: rotateLeft)
            transform(
                String(localized: "crop.flip_horizontal", defaultValue: "Flip Horizontal"),
                symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                action: flipHorizontal)
            transform(
                String(localized: "crop.flip_vertical", defaultValue: "Flip Vertical"),
                symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                action: flipVertical)
        }
    }
    private func transform(_ title: String, symbol: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 24) }
            .accessibilityLabel(title).buttonStyle(.glass).buttonBorderShape(.circle)
    }

    private var orientationButtons: some View {
        Group {
            Button(
                String(localized: "crop.portrait", defaultValue: "Portrait"),
                systemImage: "rectangle.portrait"
            ) {
                crop.setOrientation(.portrait, imageAspect: imageAspect)
            }
            .tint(crop.orientation == .portrait ? Color.accentColor : .secondary)
            .accessibilityAddTraits(crop.orientation == .portrait ? .isSelected : [])
            .accessibilityIdentifier("crop.portrait")
            Button(
                String(localized: "crop.landscape", defaultValue: "Landscape"),
                systemImage: "rectangle"
            ) {
                crop.setOrientation(.landscape, imageAspect: imageAspect)
            }
            .tint(crop.orientation == .landscape ? Color.accentColor : .secondary)
            .accessibilityAddTraits(crop.orientation == .landscape ? .isSelected : [])
            .accessibilityIdentifier("crop.landscape")
        }.labelStyle(.titleAndIcon)
    }

    private var straightenValue: some View {
        Button(geometry.straightenDegrees.formatted(.number.precision(.fractionLength(1))) + "°") {
            geometry.straightenDegrees = 0
        }
        .monospacedDigit()
        .accessibilityLabel(
            String(localized: "crop.reset_straightening", defaultValue: "Reset Straightening"))
    }
}
