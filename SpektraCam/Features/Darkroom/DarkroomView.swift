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
    /// Full-resolution pixels for the loupe, when the workspace has rendered them.
    var loupeImage: UIImage? = nil
    var loupeRefining = false
    var loupeWidth: CGFloat? = nil
    var loupePatch: PhotoRenderer.Detail? = nil
    var onLoupeInspect: ((CGRect) -> Void)? = nil
    @Binding var showLoupe: Bool
    @State private var loupeCenter: CGPoint?
    @AppStorage("darkroom.light.on") private var tableLit = true
    @State private var expanded = false
    @State private var fineTune = false
    private enum Style: String { case cleanPrint, filmEdge }
    /// A film-edge enlarger print starts on 5 × 7; anything else starts as the photo itself.
    private var current: PrintLayout {
        if let layout { return layout }
        if case .enlarger = content { return .enlargerDefault }
        return PrintLayout()
    }
    private var sourceSize: CGSize { printSourceSize ?? image.size }
    /// What is on the sheet: the picture, or a film-edge canvas with or without its own easel.
    private var content: PrintGeometry.Content {
        guard let edge else { return .picture }
        return resolvedType == .negativePrint ? .enlarger(frame: edge.easelFrame(canvas: sourceSize)) : .scan
    }

    var body: some View {
        GeometryReader { workspace in
            VStack(spacing: 12) {
                PrintPreview(image: imageReady ? image : nil, imageSize: sourceSize, layout: current, content: content,
                             paperColor: edge != nil && resolvedType == .negativePrint ? PaperTone.color(of: image) : .white,
                             loupeImage: loupeImage, loupeRefining: loupeRefining, loupeWidth: loupeWidth,
                             loupePatch: loupePatch, onLoupeInspect: onLoupeInspect,
                             showLoupe: showLoupe, tableLit: tableLit, loupeCenter: $loupeCenter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomLeading) { LightTableSwitch(lit: $tableLit) }
                    .overlay(alignment: .topLeading) {
                        Button(showLoupe ? String(localized: "darkroom.hide_loupe", defaultValue: "Hide loupe")
                                         : String(localized: "darkroom.show_loupe", defaultValue: "Show loupe"),
                               systemImage: showLoupe ? "magnifyingglass.circle.fill" : "magnifyingglass.circle") {
                            showLoupe.toggle()
                        }
                        .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                        .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("darkroom.loupe.toggle")
                    }
                inspector(height: min(expanded ? 360 : 202, max(160, workspace.size.height * 0.55)))
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { LightTableBackdrop(lit: tableLit) }
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
                        paperControls
                        if showsEasel { easelControls }
                    }
                    .font(.footnote).padding(16)
                }
                .frame(height: height)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
            }
        }
    }

    private enum FormatChoice: String { case film35, cine35, roll120 }
    /// Auto, or one of the film-edge types (by raw value).
    private struct EdgeChoice: RawRepresentable, Hashable {
        let rawValue: String
        static let auto = EdgeChoice(rawValue: "auto")
    }
    private var formatChoice: FormatChoice {
        guard let edge else { return .film35 }
        if edge.format == .roll120 { return .roll120 }
        return edge.cinePerforations ? .cine35 : .film35
    }
    private var edgeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One row: Auto follows Develop; a type pins the edge. Auto keeps the last pinned type.
            PanelTabs(
                options: [(EdgeChoice.auto, String(localized: "common.auto", defaultValue: "Auto"))]
                    + FilmEdgeType.allCases.map { (EdgeChoice(rawValue: $0.rawValue), $0.title) },
                selection: Binding(get: {
                    let current = edgeSelection ?? FilmEdgeSelection()
                    return current.mode == .automatic ? .auto : EdgeChoice(rawValue: current.manualType.rawValue)
                }, set: { choice in
                    var next = edgeSelection ?? FilmEdgeSelection()
                    if let type = FilmEdgeType(rawValue: choice.rawValue) {
                        next.mode = .manual
                        next.manualType = type
                    } else {
                        next.mode = .automatic
                    }
                    edgeSelection = next
                }),
                prefix: "darkroom.edge.type.")
            if (edgeSelection ?? FilmEdgeSelection()).mode == .automatic {
                LabeledContent(String(localized: "darkroom.edge.from_develop", defaultValue: "From Develop"), value: resolvedType.title)
                    .font(.caption).accessibilityIdentifier("darkroom.edge.resolved")
            }
            PanelTabs(
                options: [(FormatChoice.film35, "35 mm"),
                          (.cine35, String(localized: "darkroom.edge.cine35", defaultValue: "35 mm cine")),
                          (.roll120, "120")],
                selection: Binding(get: { formatChoice }, set: { choice in
                    var next = edge ?? FilmEdgeLayout.newDefault()
                    next.format = choice == .roll120 ? .roll120 : .film35
                    next.cinePerforations = choice == .cine35
                    edge = next
                }),
                prefix: "darkroom.edge.format.")
            if edge?.format == .roll120 {
                PanelTabs(
                    options: FilmEdgeLayout.RollFrame.allCases.map { ($0, $0.title) },
                    selection: Binding(get: { edge?.rollFrame ?? .six6 }, set: { frame in
                        var next = edge ?? FilmEdgeLayout.newDefault()
                        next.rollFrame = frame
                        edge = next
                    }),
                    prefix: "darkroom.edge.frame.")
                PanelTabs(
                    options: FilmEdgeLayout.RollGate.allCases.map { ($0, $0.title) },
                    selection: Binding(get: { edge?.rollGate ?? .hasselblad }, set: { body in
                        var next = edge ?? FilmEdgeLayout.newDefault()
                        next.rollGate = body
                        edge = next
                    }),
                    prefix: "darkroom.edge.body.")
            }
            ViewThatFits(in: .horizontal) {
                HStack { gateSize; Spacer(); cropButton }
                VStack(alignment: .leading, spacing: 6) { gateSize; cropButton }
            }
            Divider().padding(.vertical, 4)
            gateControls
            if resolvedType == .negativePrint { zoomControl } else { scanZoomControl }
            Divider().padding(.vertical, 4)
            distressControls
            Divider().padding(.vertical, 4)
        }
    }

    // MARK: Gate — the camera and holder. Fixed per setup, remembered for the next edit.
    private var gate: FilmEdgeGate { edge?.gate ?? FilmEdgeGate() }
    private func setGate(_ change: (inout FilmEdgeGate) -> Void) {
        var next = edge ?? FilmEdgeLayout.newDefault()
        change(&next.gate)
        edge = next
    }
    private var gateControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "darkroom.gate", defaultValue: "Gate")).foregroundStyle(.secondary)
                if gate.kind == nil {
                    Text(String(localized: "darkroom.distress.custom", defaultValue: "Custom"))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            PanelTabs(
                options: FilmEdgeGate.Kind.allCases.map { ($0, $0.title) },
                selection: Binding(get: { gate.kind ?? .natural }, set: { kind in setGate { $0 = FilmEdgeGate(kind) } }),
                prefix: "darkroom.gate.", isSelectionActive: gate.kind != nil)
        }
    }

    // MARK: Distress — how the film was handled. Presets for a quick start, every field for fine control.
    private var distress: FilmEdgeDistress { edge?.distress ?? FilmEdgeLayout.newDefault().distress }
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
                selection: Binding(get: { distress.preset ?? .lab }, set: { preset in setDistress { $0.apply(preset) } }),
                prefix: "darkroom.distress.", isSelectionActive: distress.preset != nil)
            distressSlider(String(localized: "darkroom.distress.amount", defaultValue: "Amount"), \.amount,
                           scale: 100, step: 1, unit: "%", identifier: "amount")
            DisclosureGroup(isExpanded: $fineTune) {
                VStack(alignment: .leading, spacing: 10) {
                    distressGroup(String(localized: "darkroom.distress.handling", defaultValue: "Handling")) {
                        distressSlider(String(localized: "darkroom.distress.extra_tilt", defaultValue: "Crooked loading"), \.tilt,
                                       step: 0.05, unit: "°", identifier: "tilt", fillOrigin: 0)
                        distressSlider(String(localized: "darkroom.distress.curl", defaultValue: "Film curl"), \.bulge,
                                       scale: 100, step: 1, unit: "%", identifier: "bulge", fillOrigin: 0)
                        distressSlider(String(localized: "darkroom.distress.hole_variation", defaultValue: "Hole variation"), \.holeVariation,
                                       scale: 100, step: 1, unit: "%", identifier: "holeVariation")
                    }
                    distressGroup(String(localized: "darkroom.distress.light", defaultValue: "Fog and leaks")) {
                        distressSlider(String(localized: "darkroom.distress.edge_fog", defaultValue: "Edge fog"), \.edgeFog,
                                       scale: 100, step: 1, unit: "%", identifier: "fog")
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
                            Text(String(localized: "darkroom.distress.shape_burn", defaultValue: "Burn")).tag(FilmEdgeDistress.LeakShape.burn)
                        }.pickerStyle(.segmented).accessibilityIdentifier("darkroom.distress.leakShape")
                        distressSlider(String(localized: "darkroom.distress.leak_strength", defaultValue: "Leak"), \.leak,
                                       scale: 100, step: 1, unit: "%", identifier: "leak")
                        distressSlider(String(localized: "darkroom.distress.leak_size", defaultValue: "Leak size"), \.leakSize,
                                       step: 0.5, unit: "mm", identifier: "leakSize")
                        distressSlider(String(localized: "darkroom.distress.leak_position", defaultValue: "Leak position"), \.leakPosition,
                                       scale: 100, step: 1, unit: "%", identifier: "leakPosition")
                    }
                    distressGroup(String(localized: "darkroom.distress.damage", defaultValue: "Dust and scratches")) {
                        distressSlider(String(localized: "darkroom.distress.dust", defaultValue: "Dust"), \.dust,
                                       scale: 100, step: 1, unit: "%", identifier: "dust")
                        distressSlider(String(localized: "darkroom.distress.scratches", defaultValue: "Scratches"), \.scratches,
                                       scale: 100, step: 1, unit: "%", identifier: "scratches")
                        Toggle(String(localized: "darkroom.distress.scratches_in_image", defaultValue: "Scratches cross the picture"),
                               isOn: Binding(get: { distress.scratchesInImage }, set: { on in setDistress { $0.scratchesInImage = on } }))
                            .accessibilityIdentifier("darkroom.distress.scratchesInImage")
                    }
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
            defaultValue: FilmEdgeLayout.newDefault().distress[keyPath: path] * scale,
            fillOrigin: fillOrigin ?? scaled.lowerBound, onEditingChanged: onEdgeEditingChanged)
    }
    // MARK: Enlarger — the head's height sets how much of the frame the easel opening shows.
    private var zoomControl: some View {
        let layout = edge ?? FilmEdgeLayout.newDefault()
        let border = layout.easelBorder
        func mm(_ v: Double) -> String { abs(v).formatted(.number.precision(.fractionLength(2))) }
        let readout = abs(border.ends) < 0.005
            ? String(localized: "darkroom.easel.on_edge", defaultValue: "On the frame edge")
            : border.ends > 0
                ? String(localized: "darkroom.easel.rebate", defaultValue: "Rebate \(mm(border.ends)) × \(mm(border.sides)) mm")
                : String(localized: "darkroom.easel.cropped", defaultValue: "Crop \(mm(border.ends)) × \(mm(border.sides)) mm")
        return VStack(alignment: .leading, spacing: 3) {
            NumericControl(
                title: String(localized: "darkroom.easel.zoom", defaultValue: "Enlarger zoom"),
                value: Binding(get: { layout.printZoom * 100 }, set: { value in
                    var next = edge ?? FilmEdgeLayout.newDefault()
                    let range = FilmEdgeLayout.printZoomRange
                    next.printZoom = min(max(value / 100, range.lowerBound), range.upperBound)
                    edge = next
                }),
                range: 90...110, step: 0.5, minimum: 90, maximum: 110, unit: "%",
                identifier: "darkroom.easel.zoom", defaultValue: 97, fillOrigin: 100,
                onEditingChanged: onEdgeEditingChanged)
            Text(readout).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("darkroom.easel.readout")
        }
    }
    /// The scan's counterpart to the enlarger zoom: how far past the frame the scanner's crop reaches.
    private var scanZoomControl: some View {
        let layout = edge ?? FilmEdgeLayout.newDefault()
        return NumericControl(
            title: String(localized: "darkroom.edge.scan_zoom", defaultValue: "Scan framing"),
            value: Binding(get: { layout.scanZoom * 100 }, set: { value in
                var next = edge ?? FilmEdgeLayout.newDefault()
                let range = FilmEdgeLayout.scanZoomRange
                next.scanZoom = min(max(value / 100, range.lowerBound), range.upperBound)
                edge = next
            }),
            range: 75...105, step: 0.5, minimum: 75, maximum: 105, unit: "%",
            identifier: "darkroom.edge.scanZoom", defaultValue: 90, fillOrigin: 100,
            onEditingChanged: onEdgeEditingChanged)
    }
    // MARK: Easel — blades on the paper: their edge and how they were set.
    /// Blades show wherever there is a border (or a film-edge enlarger print, which has its own).
    private var showsEasel: Bool {
        if case .enlarger = content { return true }
        return content == .picture && current.resolvedMargin(content) > 0
    }
    private var easelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "darkroom.easel", defaultValue: "Easel")).foregroundStyle(.secondary)
                Spacer()
                Toggle(String(localized: "darkroom.easel.hand_set", defaultValue: "Hand-set"), isOn: binding(\.handSet))
                    .fixedSize().accessibilityIdentifier("darkroom.easel.handSet")
                Button(String(localized: "darkroom.easel.new_placement", defaultValue: "New placement"), systemImage: "dice") {
                    var next = current
                    next.easelSeed = UInt32.random(in: 2...UInt32.max)
                    layout = next
                }
                .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("darkroom.easel.seed")
            }
            PanelTabs(options: Easel.Kind.allCases.map { ($0, $0.title) }, selection: binding(\.blade), prefix: "darkroom.easel.blade.")
        }
    }
    private var gateSize: some View {
        Text((edge ?? FilmEdgeLayout()).gateTitle(portrait: sourceSize.height > sourceSize.width))
            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("darkroom.edge.gate")
    }
    private var cropButton: some View {
        Button(String(localized: "darkroom.edge.adjust_crop", defaultValue: "Adjust crop"), systemImage: "crop", action: adjustCrop)
            .accessibilityIdentifier("darkroom.edge.adjustCrop")
    }

    // MARK: Paper — the sheet and the easel's white border.
    private var paperControls: some View {
        // Percent of the sheet's long side; below zero the picture runs past the sheet's edge.
        let fill = PrintGeometry.fillMargin(imageSize: sourceSize, layout: current, content: content)
        let margin = current.fill ? fill : current.resolvedMargin(content)
        let filled = abs(margin - fill) < 0.0005
        func setMargin(_ value: Double) {
            var next = current
            next.fill = false
            next.margin = min(max(value, PrintLayout.marginRange.lowerBound), PrintLayout.marginRange.upperBound)
            layout = next
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(String(localized: "darkroom.paper", defaultValue: "Paper"), selection: binding(\.paper)) {
                    ForEach(PrintLayout.Paper.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).accessibilityIdentifier("darkroom.paper")
                if current.paper != .asImage {
                    Button(String(localized: "darkroom.rotate_paper", defaultValue: "Rotate paper"), systemImage: "rotate.right") {
                        var next = current
                        let landscape = current.paperAspect(imageAspect: sourceSize.width / sourceSize.height) > 1
                        next.orientation = landscape ? .portrait : .landscape
                        layout = next
                    }
                    .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                    .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("darkroom.rotatePaper")
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                NumericControl(
                    title: String(localized: "darkroom.border", defaultValue: "Border"),
                    value: Binding(get: { margin * 100 }, set: { setMargin($0 / 100) }),
                    range: (PrintLayout.marginRange.lowerBound * 100)...(PrintLayout.marginRange.upperBound * 100), step: 0.5,
                    minimum: PrintLayout.marginRange.lowerBound * 100, maximum: PrintLayout.marginRange.upperBound * 100, unit: "%",
                    identifier: "darkroom.border",
                    defaultValue: { var d = current; d.margin = nil; d.fill = false; return d.resolvedMargin(content) * 100 }(),
                    fillOrigin: 0, onEditingChanged: onEditingChanged)
                Button(String(localized: "darkroom.fill", defaultValue: "Fill")) { setMargin(fill) }
                    .buttonStyle(.glass).tint(filled ? .accentColor : nil)
                    .accessibilityValue(filled ? String(localized: "common.on", defaultValue: "On") : String(localized: "common.off", defaultValue: "Off"))
                    .accessibilityIdentifier("darkroom.fill")
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PrintLayout, Value>) -> Binding<Value> {
        Binding(get: { current[keyPath: keyPath] }, set: { value in
            var next = current
            next[keyPath: keyPath] = value
            layout = next.isDefault ? nil : next
        })
    }
}

private struct PrintPreview: View {
    let image: UIImage?
    let imageSize: CGSize
    let layout: PrintLayout
    var content = PrintGeometry.Content.picture
    /// The sheet continues the print's own unexposed margin.
    var paperColor = Color.white
    var loupeImage: UIImage? = nil
    var loupeRefining = false
    /// Pixel width the loupe's full-resolution frame will have, known before it is rendered.
    var loupeWidth: CGFloat? = nil
    var loupePatch: PhotoRenderer.Detail? = nil
    var onLoupeInspect: ((CGRect) -> Void)? = nil
    var showLoupe = false
    var tableLit = true
    @Binding var loupeCenter: CGPoint?
    var body: some View {
        GeometryReader { viewport in
            if let geometry = PrintGeometry(imageSize: imageSize, layout: layout, longEdge: 1000, content: content) {
                let blades = bladeMask(geometry)
                let fit = min(max(1, viewport.size.width - 44) / geometry.paperSize.width,
                              max(1, viewport.size.height - 36) / geometry.paperSize.height)
                let paper = CGSize(width: geometry.paperSize.width * fit, height: geometry.paperSize.height * fit)
                PrintSheet(image: image, size: paper,
                           imageRect: CGRect(x: geometry.imageRect.minX * fit, y: geometry.imageRect.minY * fit,
                                             width: geometry.imageRect.width * fit, height: geometry.imageRect.height * fit),
                           paper: paperColor, blades: blades)
                .shadow(color: .black.opacity(0.18), radius: 7, x: 0, y: 4)
                .position(x: viewport.size.width / 2, y: viewport.size.height / 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "darkroom.print_preview", defaultValue: "Print preview"))
                .accessibilityValue(layout.paper.title + ", " + (geometry.paperSize.width > geometry.paperSize.height
                    ? String(localized: "crop.landscape", defaultValue: "Landscape")
                    : String(localized: "crop.portrait", defaultValue: "Portrait")))
                .accessibilityIdentifier("darkroom.preview")
                if showLoupe, let source = loupeImage ?? image {
                    let paperFrame = CGRect(x: (viewport.size.width - paper.width) / 2, y: (viewport.size.height - paper.height) / 2,
                                            width: paper.width, height: paper.height)
                    DarkroomLoupe(image: source,
                                  imageFrame: CGRect(x: paperFrame.minX + geometry.imageRect.minX * fit,
                                                     y: paperFrame.minY + geometry.imageRect.minY * fit,
                                                     width: geometry.imageRect.width * fit, height: geometry.imageRect.height * fit),
                                  paperFrame: paperFrame, bounds: viewport.size,
                                  refining: loupeRefining || (loupeImage == nil && loupePatch == nil),
                                  surround: LightTableBackdrop.surround(lit: tableLit), paper: paperColor,
                                  fullWidth: loupeWidth, patch: loupePatch,
                                  blades: blades,
                                  onInspect: onLoupeInspect,
                                  center: $loupeCenter)
                }
            }
        }
    }
    /// The clean print's blade mask, at the loupe's resolution so its edge holds up at 100 %.
    private func bladeMask(_ geometry: PrintGeometry) -> CGImage? {
        guard geometry.magnification > 0 else { return nil }
        let long = min(4096, max(loupeWidth.map { $0 * max(1, imageSize.height / imageSize.width) } ?? 0,
                                 max(imageSize.width, imageSize.height), 1000))
        let k = long / max(imageSize.width, imageSize.height)
        return Easel.mask(width: Int((imageSize.width * k).rounded()), height: Int((imageSize.height * k).rounded()),
                          magnification: geometry.magnification, kind: layout.blade, seed: layout.easelSeed)
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
    DarkroomView(image: DarkroomFixture.image, layout: $layout, edge: .constant(nil), edgeSelection: .constant(nil), showLoupe: .constant(true))
}

#Preview("Portrait paper · Larger text") {
    @Previewable @State var layout: PrintLayout? = {
        var value = PrintLayout()
        value.paper = .eightByTen
        value.orientation = .portrait
        value.margin = 0.08
        return value
    }()
    DarkroomView(image: DarkroomFixture.image, layout: $layout, edge: .constant(nil), edgeSelection: .constant(nil), showLoupe: .constant(true))
        .environment(\.dynamicTypeSize, .accessibility1)
}
#endif
