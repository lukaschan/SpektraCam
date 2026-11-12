import SwiftUI
import UIKit

/// A feature-local workspace; the owning editor retains the session, history and export lifecycle.
struct DarkroomView: View {
    let image: UIImage
    @Binding var layout: PrintLayout?
    @Binding var edge: FilmEdgeLayout?
    @Binding var edgeSelection: FilmEdgeSelection?
    var resolvedType: FilmEdgeType = .negativePrint
    var adjustCrop: () -> Void = {}
    var printSourceSize: CGSize? = nil
    var imageReady = true
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onEdgeEditingChanged: (Bool) -> Void = { _ in }
    @State private var expanded = false
    @State private var fineTune = false
    private enum Style: String { case cleanPrint, filmEdge }
    private var current: PrintLayout { layout ?? PrintLayout() }
    private var sourceSize: CGSize { printSourceSize ?? image.size }
    private var geometry: PrintGeometry? {
        PrintGeometry(imageSize: sourceSize, layout: current, longEdge: 1000)
    }

    var body: some View {
        GeometryReader { workspace in
            VStack(spacing: 12) {
                PrintPreview(image: imageReady ? image : nil, imageSize: sourceSize, layout: current)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                inspector(height: min(expanded ? 360 : 202, max(160, workspace.size.height * 0.55)))
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { LightTableBackdrop() }
        }
        .onDisappear { onEditingChanged(false) }
    }

    private func inspector(height: CGFloat) -> some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    PanelTabs(
                        options: [
                            (Style.cleanPrint, String(localized: "darkroom.clean_print", defaultValue: "Clean print")),
                            (.filmEdge, String(localized: "darkroom.film_edge_later", defaultValue: "Film edge")),
                        ],
                        selection: Binding(get: { edge == nil ? .cleanPrint : .filmEdge },
                            set: { edge = $0 == .filmEdge ? (edge ?? FilmEdgeLayout.newDefault()) : nil }), prefix: "darkroom.")
                    PanelExpansionButton(expanded: $expanded, identifier: "darkroom.expand")
                }
                .dynamicTypeSize(...DynamicTypeSize.large)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if edge != nil { edgeControls }
                        paperControl
                        scaleControl
                        if expanded { details }
                    }
                    .font(.footnote).padding(16)
                }
                .frame(height: height)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
            }
        }
    }

    private var edgeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(String(localized: "darkroom.edge.selection", defaultValue: "Edge selection"), selection: Binding(
                get: { (edgeSelection ?? FilmEdgeSelection()).mode }, set: { mode in
                    var next = edgeSelection ?? FilmEdgeSelection()
                    next.mode = mode
                    edgeSelection = next
                })) {
                Text(String(localized: "common.auto", defaultValue: "Auto")).tag(FilmEdgeSelection.Mode.automatic)
                Text(String(localized: "darkroom.edge.manual", defaultValue: "Manual")).tag(FilmEdgeSelection.Mode.manual)
            }.pickerStyle(.segmented).accessibilityIdentifier("darkroom.edge.mode")
            if (edgeSelection ?? FilmEdgeSelection()).mode == .manual {
                Picker(String(localized: "darkroom.edge.type", defaultValue: "Edge type"), selection: Binding(
                    get: { (edgeSelection ?? FilmEdgeSelection()).manualType }, set: { type in
                        var next = edgeSelection ?? FilmEdgeSelection()
                        next.manualType = type
                        edgeSelection = next
                    })) {
                    ForEach(FilmEdgeType.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("darkroom.edge.type")
            } else {
                LabeledContent(String(localized: "darkroom.edge.from_develop", defaultValue: "From Develop"), value: resolvedType.title)
                    .accessibilityIdentifier("darkroom.edge.resolved")
            }
            Picker(String(localized: "darkroom.edge.format", defaultValue: "Film format"), selection: Binding(
                get: { edge?.format ?? .film35 }, set: { format in
                    var next = edge ?? FilmEdgeLayout.newDefault()
                    next.format = format
                    edge = next
                })) {
                Text(verbatim: "35 mm").tag(FilmEdgeLayout.Format.film35)
                Text(verbatim: "120").tag(FilmEdgeLayout.Format.roll120)
            }.pickerStyle(.segmented).accessibilityIdentifier("darkroom.edge.format")
            ViewThatFits(in: .horizontal) {
                HStack { gateSize; Spacer(); cropButton }
                VStack(alignment: .leading, spacing: 6) { gateSize; cropButton }
            }
            Text(String(localized: "darkroom.edge.aperture_note", defaultValue: "35 mm uses a fixed 3:2 crop. 120 uses a square crop without perforations."))
                .font(.caption).foregroundStyle(.secondary)
            Picker(String(localized: "darkroom.gate", defaultValue: "Gate"), selection: Binding(
                get: { edge?.gateShape ?? FilmEdgeLayout.preferredGateShape }, set: { shape in
                    var next = edge ?? FilmEdgeLayout.newDefault()
                    next.gateShape = shape
                    FilmEdgeLayout.preferredGateShape = shape
                    edge = next
                })) {
                ForEach(FilmEdgeLayout.GateShape.allCases, id: \.self) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("darkroom.edge.gateShape")
            Divider().padding(.vertical, 4)
            distressControls
        }
    }

    // MARK: Distress — presets for a quick start, every physical parameter for fine control.
    private var distress: FilmEdgeDistress { edge?.distress ?? FilmEdgeDistress() }
    private func setDistress(_ change: (inout FilmEdgeDistress) -> Void) {
        var next = edge ?? FilmEdgeLayout.newDefault()
        change(&next.distress)
        edge = next
    }
    private func distressBinding(_ path: WritableKeyPath<FilmEdgeDistress, Double>, scale: Double = 1) -> Binding<Double> {
        Binding(get: { distress[keyPath: path] * scale }, set: { value in
            let range = FilmEdgeDistress.ranges[path] ?? (0...1)
            setDistress { $0[keyPath: path] = min(max(value / scale, range.lowerBound), range.upperBound) }
        })
    }
    private var distressControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "darkroom.distress", defaultValue: "Distress")).foregroundStyle(.secondary)
                if distress.preset == nil {
                    Text(String(localized: "darkroom.distress.custom", defaultValue: "Custom"))
                        .font(.caption).foregroundStyle(.tertiary).accessibilityIdentifier("darkroom.distress.customLabel")
                }
                Spacer()
                Button(String(localized: "darkroom.distress.new_seed", defaultValue: "New pattern"), systemImage: "dice") {
                    setDistress { $0.seed = UInt32.random(in: 1...UInt32.max) }
                }
                .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("darkroom.distress.seed")
            }
            PanelTabs(
                options: FilmEdgeDistress.Preset.allCases.map { ($0, $0.title) },
                selection: Binding(get: { distress.preset ?? .clean }, set: { preset in setDistress { $0.apply(preset) } }),
                prefix: "darkroom.distress.", isSelectionActive: distress.preset != nil)
            distressSlider(String(localized: "darkroom.distress.amount", defaultValue: "Amount"), \.amount,
                           scale: 100, step: 1, unit: "%", identifier: "amount")
            DisclosureGroup(isExpanded: $fineTune) {
                VStack(alignment: .leading, spacing: 10) {
                    distressGroup(String(localized: "darkroom.distress.gate", defaultValue: "Camera gate")) {
                        distressSlider(String(localized: "darkroom.distress.gate_softness", defaultValue: "Edge softness"), \.gateSoftness,
                                       scale: 1000, step: 1, unit: "µm", identifier: "softness")
                        distressSlider(String(localized: "darkroom.distress.gate_wear", defaultValue: "Gate wear"), \.gateWear,
                                       scale: 1000, step: 1, unit: "µm", identifier: "wear")
                        distressSlider(String(localized: "darkroom.distress.tilt", defaultValue: "Film tilt"), \.tilt,
                                       step: 0.01, unit: "°", identifier: "tilt", fillOrigin: 0)
                    }
                    distressGroup(String(localized: "darkroom.distress.sprockets", defaultValue: "Sprocket holes")) {
                        distressSlider(String(localized: "darkroom.distress.hole_variation", defaultValue: "Hole variation"), \.holeVariation,
                                       scale: 100, step: 1, unit: "%", identifier: "holeVariation")
                        distressSlider(String(localized: "darkroom.distress.perforation_leak", defaultValue: "Light through holes"), \.perforationLeak,
                                       scale: 100, step: 1, unit: "%", identifier: "perforationLeak")
                    }
                    distressGroup(String(localized: "darkroom.distress.carrier", defaultValue: "Carrier and holder")) {
                        distressSlider(String(localized: "darkroom.distress.carrier_blur", defaultValue: "Holder blur"), \.carrierBlur,
                                       step: 0.01, unit: "mm", identifier: "carrierBlur")
                        distressSlider(String(localized: "darkroom.distress.carrier_detail", defaultValue: "Holder edge detail"), \.carrierDetail,
                                       scale: 100, step: 1, unit: "%", identifier: "carrierDetail")
                        distressSlider(String(localized: "darkroom.distress.carrier_roughness", defaultValue: "Filed roughness"), \.carrierRoughness,
                                       step: 0.01, unit: "mm", identifier: "carrier")
                        distressSlider(String(localized: "darkroom.distress.carrier_scale", defaultValue: "Roughness scale"), \.carrierScale,
                                       step: 0.05, unit: "mm", identifier: "carrierScale")
                        distressSlider(String(localized: "darkroom.distress.carrier_reflection", defaultValue: "Edge reflection (print)"), \.carrierReflection,
                                       scale: 100, step: 1, unit: "%", identifier: "carrierReflection")
                    }
                    distressGroup(String(localized: "darkroom.distress.light", defaultValue: "Fog and leaks")) {
                        distressSlider(String(localized: "darkroom.distress.edge_fog", defaultValue: "Edge fog"), \.edgeFog,
                                       scale: 100, step: 1, unit: "%", identifier: "fog")
                        distressSlider(String(localized: "darkroom.distress.fog_depth", defaultValue: "Fog depth"), \.fogDepth,
                                       step: 0.1, unit: "mm", identifier: "fogDepth")
                        Picker(String(localized: "darkroom.distress.leak_kind", defaultValue: "Leak path"), selection: Binding(
                            get: { distress.leakKind }, set: { kind in setDistress {
                                if $0.leakKind != kind { $0.warmth = FilmEdgeDistress.defaultWarmth(kind) }
                                $0.leakKind = kind
                            } })) {
                            Text(String(localized: "darkroom.distress.leak_back", defaultValue: "Back (door, seal)")).tag(FilmEdgeDistress.LeakKind.back)
                            Text(String(localized: "darkroom.distress.leak_front", defaultValue: "Front (through lens)")).tag(FilmEdgeDistress.LeakKind.front)
                        }.pickerStyle(.segmented).accessibilityIdentifier("darkroom.distress.leakKind")
                        Picker(String(localized: "darkroom.distress.leak_shape", defaultValue: "Leak shape"), selection: Binding(
                            get: { distress.leakShape }, set: { shape in setDistress { $0.leakShape = shape } })) {
                            Text(String(localized: "darkroom.distress.shape_glow", defaultValue: "Glow")).tag(FilmEdgeDistress.LeakShape.glow)
                            Text(String(localized: "darkroom.distress.shape_streak", defaultValue: "Streak")).tag(FilmEdgeDistress.LeakShape.streak)
                            Text(String(localized: "darkroom.distress.shape_flare", defaultValue: "Flare")).tag(FilmEdgeDistress.LeakShape.flare)
                        }.pickerStyle(.segmented).accessibilityIdentifier("darkroom.distress.leakShape")
                        distressSlider(String(localized: "darkroom.distress.leak_strength", defaultValue: "Leak"), \.leak,
                                       scale: 100, step: 1, unit: "%", identifier: "leak")
                        distressSlider(String(localized: "darkroom.distress.leak_size", defaultValue: "Leak size"), \.leakSize,
                                       step: 0.5, unit: "mm", identifier: "leakSize")
                        distressSlider(String(localized: "darkroom.distress.leak_position", defaultValue: "Leak position"), \.leakPosition,
                                       scale: 100, step: 1, unit: "%", identifier: "leakPosition")
                        distressSlider(String(localized: "darkroom.distress.warmth", defaultValue: "Leak colour: cool ↔ warm"), \.warmth,
                                       scale: 100, step: 1, unit: "", identifier: "warmth", fillOrigin: 0)
                    }
                    distressGroup(String(localized: "darkroom.distress.damage", defaultValue: "Dust and scratches")) {
                        distressSlider(String(localized: "darkroom.distress.dust", defaultValue: "Dust"), \.dust,
                                       scale: 100, step: 1, unit: "%", identifier: "dust")
                        distressSlider(String(localized: "darkroom.distress.scratches", defaultValue: "Scratches"), \.scratches,
                                       scale: 100, step: 1, unit: "%", identifier: "scratches")
                        Toggle(String(localized: "darkroom.distress.scratches_in_image", defaultValue: "Scratches cross the picture"),
                               isOn: Binding(get: { distress.scratchesInImage }, set: { on in setDistress { $0.scratchesInImage = on } }))
                            .accessibilityIdentifier("darkroom.distress.scratchesInImage")
                        Text(String(localized: "darkroom.distress.scratches_note", defaultValue: "Off: rails and sprockets only touch the rebate. On: gate grit drags scratches through the picture too."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(String(localized: "darkroom.distress.note", defaultValue: "Effects follow the chosen print or scan: dust prints white on paper and dark in a scan; leaks are exposure, so the film decides their colour."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            } label: {
                Text(String(localized: "darkroom.distress.fine_tune", defaultValue: "Fine-tune"))
            }
            .accessibilityIdentifier("darkroom.distress.fineTune")
        }
    }
    private func distressGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
    private func distressSlider(_ title: String, _ path: WritableKeyPath<FilmEdgeDistress, Double>, scale: Double = 1,
                                step: Double, unit: String, identifier: String, fillOrigin: Double? = nil) -> some View {
        let range = FilmEdgeDistress.ranges[path] ?? (0...1)
        let scaled = (range.lowerBound * scale)...(range.upperBound * scale)
        return NumericControl(
            title: title, value: distressBinding(path, scale: scale), range: scaled, step: step,
            minimum: scaled.lowerBound, maximum: scaled.upperBound, unit: unit,
            identifier: "darkroom.distress." + identifier,
            defaultValue: FilmEdgeDistress()[keyPath: path] * scale,
            fillOrigin: fillOrigin ?? scaled.lowerBound, onEditingChanged: onEdgeEditingChanged)
    }
    private var gateSize: some View {
        Text((edge ?? FilmEdgeLayout()).gateTitle(portrait: sourceSize.height > sourceSize.width))
            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("darkroom.edge.gate")
    }
    private var cropButton: some View {
        Button(String(localized: "darkroom.edge.adjust_crop", defaultValue: "Adjust crop"), systemImage: "crop", action: adjustCrop)
            .accessibilityIdentifier("darkroom.edge.adjustCrop")
    }

    private var paperControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "darkroom.paper", defaultValue: "Paper"))
                .foregroundStyle(.secondary)
            Picker(String(localized: "darkroom.paper", defaultValue: "Paper"), selection: binding(\.paper)) {
                ForEach(PrintLayout.Paper.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("darkroom.paper")
        }
    }

    private var scaleControl: some View {
        VStack(spacing: 3) {
            NumericControl(
                title: String(localized: "darkroom.image_scale", defaultValue: "Image scale"),
                value: Binding(get: { current.scale * 100 }, set: { value in
                    var next = current
                    next.scale = min(max(value / 100, PrintLayout.scaleRange.lowerBound), PrintLayout.scaleRange.upperBound)
                    layout = next.isIdentity ? nil : next
                }),
                range: 25...max(100, min(400, (geometry?.fillScale ?? 1) * 100)), step: 1,
                minimum: 25, maximum: 400, unit: "%", identifier: "darkroom.scale",
                defaultValue: 100, fillOrigin: 0, onEditingChanged: onEditingChanged)
            HStack {
                Button(String(localized: "darkroom.fit", defaultValue: "Fit")) { setScale(1) }
                    .accessibilityIdentifier("darkroom.fit")
                Button(String(localized: "darkroom.fill", defaultValue: "Fill")) { setScale(geometry?.fillScale ?? 1) }
                    .disabled((geometry?.fillScale ?? 1) > PrintLayout.scaleRange.upperBound)
                    .accessibilityIdentifier("darkroom.fill")
                Spacer()
                Text(
                    geometry?.cropsImage == true
                        ? String(localized: "darkroom.cropped_to_paper", defaultValue: "Cropped to paper")
                        : String(localized: "darkroom.whole_image", defaultValue: "Whole image")
                ).font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if current.paper != .asImage {
                HStack {
                    Text(String(localized: "darkroom.orientation", defaultValue: "Orientation"))
                    Spacer()
                    Button(
                        String(localized: "darkroom.rotate_paper", defaultValue: "Rotate paper"),
                        systemImage: "rotate.right"
                    ) {
                        var next = current
                        let landscape = current.paperAspect(imageAspect: sourceSize.width / sourceSize.height) > 1
                        next.orientation = landscape ? .portrait : .landscape
                        layout = next
                    }
                    .accessibilityIdentifier("darkroom.rotatePaper")
                }
                Text(String(localized: "darkroom.paper_inches", defaultValue: "Paper sizes are in inches. Export size controls pixels."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(String(localized: "darkroom.reset_layout", defaultValue: "Reset print layout")) { layout = nil }
                .disabled(layout == nil).accessibilityIdentifier("darkroom.reset")
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PrintLayout, Value>) -> Binding<Value> {
        Binding(get: { current[keyPath: keyPath] }, set: { value in
            var next = current
            next[keyPath: keyPath] = value
            layout = next.isIdentity ? nil : next
        })
    }
    private func setScale(_ value: Double) {
        var next = current
        next.scale = min(max(value, PrintLayout.scaleRange.lowerBound), PrintLayout.scaleRange.upperBound)
        layout = next.isIdentity ? nil : next
    }
}

private struct PrintPreview: View {
    let image: UIImage?
    let imageSize: CGSize
    let layout: PrintLayout
    var body: some View {
        GeometryReader { viewport in
            if let geometry = PrintGeometry(imageSize: imageSize, layout: layout, longEdge: 1000) {
                let fit = min(max(1, viewport.size.width - 44) / geometry.paperSize.width,
                              max(1, viewport.size.height - 36) / geometry.paperSize.height)
                let paper = CGSize(width: geometry.paperSize.width * fit, height: geometry.paperSize.height * fit)
                ZStack(alignment: .topLeading) {
                    Color.white
                    if let image { Image(uiImage: image).resizable()
                        .frame(width: geometry.imageRect.width * fit, height: geometry.imageRect.height * fit)
                        .position(x: geometry.imageRect.midX * fit, y: geometry.imageRect.midY * fit)
                    }
                }
                .frame(width: paper.width, height: paper.height).clipped()
                .shadow(color: .black.opacity(0.18), radius: 7, x: 0, y: 4)
                .position(x: viewport.size.width / 2, y: viewport.size.height / 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "darkroom.print_preview", defaultValue: "Print preview"))
                .accessibilityValue(layout.paper.title + ", " + (geometry.paperSize.width > geometry.paperSize.height
                    ? String(localized: "crop.landscape", defaultValue: "Landscape")
                    : String(localized: "crop.portrait", defaultValue: "Portrait")))
                .accessibilityIdentifier("darkroom.preview")
            }
        }
    }
}

#if DEBUG
private enum DarkroomFixture {
    static let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { context in
        UIColor(red: 0.4, green: 0.58, blue: 0.68, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        UIColor(red: 0.24, green: 0.37, blue: 0.31, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 220, width: 600, height: 180))
        UIColor(red: 0.86, green: 0.76, blue: 0.57, alpha: 1).setFill()
        context.fill(CGRect(x: 60, y: 180, width: 180, height: 150))
    }
}

#Preview("Clean print") {
    @Previewable @State var layout: PrintLayout? = nil
    DarkroomView(image: DarkroomFixture.image, layout: $layout, edge: .constant(nil), edgeSelection: .constant(nil))
}

#Preview("Portrait paper · Larger text") {
    @Previewable @State var layout: PrintLayout? = {
        var value = PrintLayout()
        value.paper = .eightByTen
        value.orientation = .portrait
        value.scale = 0.8
        return value
    }()
    DarkroomView(image: DarkroomFixture.image, layout: $layout, edge: .constant(nil), edgeSelection: .constant(nil))
        .environment(\.dynamicTypeSize, .accessibility1)
}
#endif
