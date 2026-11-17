import AVKit
import SwiftUI

/// RAW camera. The viewfinder stays clear; every control sits around it, with the shutter and
/// the LVF hold under the right thumb.
struct CameraView: View {
    @State private var model: CameraModel
    let onLibrary: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var layout = WorkspaceLayout.stacked
    @State private var glyphs = CameraGlyphRotation()
    /// False once the system has refused to hold the interface in portrait.
    @State private var portraitHeld = true
    /// Degrees that turn a symbol or label upright in the hand; the control itself never moves.
    /// Only when the interface is really held in portrait: a refused hold, or a space wider
    /// than tall, means the interface has followed the device and glyphs are already upright.
    private var glyphDegrees: Double { portraitHeld && layout == .stacked ? glyphs.degrees : 0 }
    private var turn: Angle { .degrees(glyphDegrees) }

    init(library: PhotoLibrary, onLibrary: @escaping () -> Void) {
        _model = State(initialValue: CameraModel(library: library))
        self.onLibrary = onLibrary
    }
    private var ready: Bool { model.state == .ready }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                viewfinder
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(
                        String(localized: "camera.close_camera", defaultValue: "Close Camera"),
                        systemImage: "xmark"
                    ) { dismiss() }
                    .labelStyle(.iconOnly).buttonBorderShape(.circle)
                    .disabled(model.busy).accessibilityIdentifier("camera.close")
                }
                ToolbarSpacer(.fixed, placement: .topBarLeading)
                ToolbarItem(placement: .topBarLeading) {
                    formatControl.frame(width: 84, height: 32).accessibilityIdentifier(
                        "camera.format")
                }.sharedBackgroundVisibility(.visible)
                ToolbarItem(placement: .principal) {
                    CameraHistogram(model: model).frame(width: 100, height: 32)
                        .opacity(ready ? 1 : 0)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    CameraExposureReadout(model: model).frame(width: 84, height: 32)
                        .accessibilityIdentifier("camera.exposureInfo")
                }.sharedBackgroundVisibility(.visible)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 14) {
                    importFailure
                    // The same optics row in every window shape. Equal side controls and
                    // independent centering keep lens selection in the same predictable place.
                    Group {
                        exposureControl
                        ZStack {
                            HStack {
                                flashButton
                                Spacer()
                                flipButton
                            }
                            lensPicker
                        }
                    }
                    .disabled(!ready)
                    if layout == .stacked {
                        ZStack {
                            HStack {
                                libraryButton
                                Spacer()
                                holdButton
                            }
                            shutterSlot
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            .safeAreaInset(edge: .trailing) {
                // Wider than tall: the shutter column moves under the thumb on the trailing edge.
                if layout == .sideBySide {
                    VStack {
                        libraryButton
                        Spacer(minLength: 0)
                        holdButton
                    }
                    .frame(width: 78)
                    .overlay { shutterSlot }
                    .padding(.vertical).padding(.trailing, 12)
                }
            }
        }
        .overlayPreferenceValue(CameraShutterBounds.self) { anchor in
            if let anchor {
                GeometryReader { proxy in
                    let slot = proxy[anchor]
                    // The slot supplies the edge placement; the full presentation supplies
                    // the center axis. Neither accessory widths nor system bars can shift it.
                    shutterButton.position(
                        x: layout == .stacked ? proxy.size.width / 2 : slot.midX,
                        y: layout == .sideBySide ? proxy.size.height / 2 : slot.midY)
                }
                .ignoresSafeArea(.container)
            }
        }
        .onGeometryChange(for: WorkspaceLayout.self) { WorkspaceLayout($0.size) } action: { layout = $0 }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.busy)
        .task {
            await model.retryImport()
            await model.setActive(scenePhase != .background)
            await model.monitor()
        }
        .onChange(of: scenePhase) { _, phase in
            // Permission prompts and transient overlays make the scene inactive. Only background
            // transitions stop capture; AVFoundation reports hardware interruptions separately.
            if phase != .inactive { Task { await model.setActive(phase == .active) } }
        }
        .onAppear {
            AppDelegate.lockPortrait(true) { portraitHeld = false }
            glyphs.start()
        }
        .task(id: layout) {
            // The window is the evidence. If it is still wider than tall once a rotation would
            // have finished, the display did not take the hold: let go of it, so the app never
            // claims portrait-only while it is shown in landscape.
            guard layout == .sideBySide, portraitHeld else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, layout == .sideBySide else { return }
            portraitHeld = false
            AppDelegate.lockPortrait(false)
        }
        .onDisappear {
            glyphs.stop()
            AppDelegate.lockPortrait(false)
            Task { await model.close() }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: glyphDegrees)
    }

    // MARK: Viewfinder

    private var viewfinder: some View {
        CameraViewfinder(model: model, landscape: layout == .sideBySide) {
            if !ready { status }
        }
            .padding(.horizontal, layout == .stacked ? 6 : 12)
            // Hardware capture follows the same readiness as the shutter. A held camera has
            // no running session, so volume buttons retain their system behavior until resumed.
            .onCameraCaptureEvent(isEnabled: scenePhase == .active && model.canCapture) { event in
                if event.phase == .ended { Task { await model.takePhoto() } }
            }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .ready: EmptyView()
        case .starting:
            ProgressView().controlSize(.large)
                .accessibilityLabel(
                    String(localized: "camera.starting_camera", defaultValue: "Starting camera…"))
        case .paused:
            CameraHoldScreen(held: model.held, reason: model.pauseReason, turn: turn) {
                Task { await model.toggleHold() }
            }
        case .unavailable:
            ContentUnavailableView(
                String(localized: "camera.camera_unavailable", defaultValue: "Camera Unavailable"),
                systemImage: "camera",
                description: Text(
                    String(
                        localized: "camera.raw_needs_device",
                        defaultValue: "RAW capture needs a physical device."))
            )
            .accessibilityIdentifier("camera.unavailable")
        case .rawUnsupported:
            ContentUnavailableView(
                String(localized: "camera.raw_unavailable", defaultValue: "RAW Capture Unavailable"),
                systemImage: "camera",
                description: Text(
                    String(
                        localized: "camera.raw_unsupported_note",
                        defaultValue: "This device’s cameras do not provide a supported RAW format. You can still import and edit photos."))
            )
            .accessibilityIdentifier("camera.rawUnsupported")
        case .denied:
            ContentUnavailableView {
                Label(
                    String(localized: "camera.camera_access", defaultValue: "Camera Access"),
                    systemImage: "camera")
            } description: {
                Text(
                    String(
                        localized: "camera.access_denied",
                        defaultValue: "Allow camera access in Settings to take photos."))
            } actions: {
                Button(String(localized: "camera.open_settings", defaultValue: "Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.buttonStyle(.glass)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label(
                    String(localized: "camera.camera_stopped", defaultValue: "Camera Stopped"),
                    systemImage: "camera")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: "common.retry", defaultValue: "Retry")) {
                    Task { await model.setActive(true) }
                }.buttonStyle(.glass)
            }
        }
    }

    // MARK: Controls

    private var shutterSlot: some View {
        Color.clear.frame(width: 78, height: 78)
            .anchorPreference(key: CameraShutterBounds.self, value: .bounds) { $0 }
            .allowsHitTesting(false)
    }

    private var exposureControl: some View {
        CameraExposureControl(
            value: Binding(get: { model.exposureBias }, set: model.setExposureBias),
            range: model.exposureRange, glyphTurn: glyphDegrees
        ).disabled(model.busy)
    }

    @ViewBuilder private var importFailure: some View {
        if let failure = model.saveFailure {
            VStack(spacing: 8) {
                Text(failure).font(.footnote)
                if model.pendingCount > 0 {
                    Text(
                        String(
                            localized: "camera.capture_kept",
                            defaultValue: "The capture is kept on this device.")
                    ).font(.footnote)
                    Button(String(localized: "camera.retry_import", defaultValue: "Retry Import")) {
                        Task { await model.retryImport() }
                    }
                    .buttonStyle(.glass).disabled(model.busy)
                    .accessibilityIdentifier("camera.retryImport")
                }
            }.padding().glassEffect(in: .rect(cornerRadius: 20))
        }
    }

    /// One capsule for the rear lenses, with macro beside them when the device has it.
    private var lensPicker: some View {
        HStack(spacing: 2) {
            if model.selectedLens?.front != true && model.lenses.contains(where: \.macro) {
                Button {
                    Task { await model.toggleMacro() }
                } label: {
                    Image(systemName: "camera.macro").font(.system(size: 15, weight: .medium))
                        .rotationEffect(turn).modifier(LensSegment(selected: model.macro))
                }
                .accessibilityLabel(String(localized: "camera.macro", defaultValue: "Macro"))
                .accessibilityAddTraits(model.macro ? .isSelected : [])
                .accessibilityIdentifier("camera.macro")
            }
            ForEach(model.lenses.filter { !$0.front && model.selectedLens?.front != true }) { lens in
                let selected = lens.id == model.selectedLens?.id
                Button {
                    Task { await model.selectLens(lens) }
                } label: {
                    Text(lens.title).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .fixedSize().rotationEffect(turn).modifier(LensSegment(selected: selected))
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("camera.lens.\(lens.millimeters)")
                .accessibilityLabel(
                    String(
                        localized: "camera.millimeter_lens",
                        defaultValue: "\(lens.millimeters) millimeter lens"))
            }
            if model.selectedLens?.front == true {
                Text(String(localized: "camera.front", defaultValue: "Front"))
                    .font(.system(size: 13, weight: .semibold)).fixedSize().rotationEffect(turn)
                    .modifier(LensSegment(selected: true))
                    .accessibilityLabel(
                        String(localized: "camera.front_camera", defaultValue: "Front camera"))
            }
        }
        .buttonStyle(.plain).padding(4)
        .glassEffect(.regular, in: .capsule)
        .disabled(model.busy).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var flashButton: some View {
        Button {
            model.flashOn.toggle()
        } label: {
            Image(systemName: model.flashOn ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(model.flashOn ? Color.yellow : Color.primary)
                .rotationEffect(turn).modifier(CameraRoundControl())
        }
        .buttonStyle(.plain)
        .disabled(!model.flashAvailable || model.busy)
        .opacity(model.flashAvailable ? 1 : 0.35)
        .accessibilityLabel(String(localized: "camera.flash", defaultValue: "Flash"))
        .accessibilityValue(
            model.flashOn
                ? String(localized: "common.on", defaultValue: "On")
                : String(localized: "common.off", defaultValue: "Off")
        )
        .accessibilityIdentifier("camera.flash")
    }

    private var flipButton: some View {
        Button {
            Task { await model.flip() }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 16, weight: .medium))
                .rotationEffect(turn).modifier(CameraRoundControl())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "camera.flip_camera", defaultValue: "Flip Camera"))
        .disabled(model.busy || !model.canFlip)
        .accessibilityIdentifier("camera.flip")
    }

    /// LVF, as on a camera body: switches the live view off and on. Off stops the sensor and
    /// the preview, which is what drains the battery between shots.
    private var holdButton: some View {
        Button {
            Task { await model.toggleHold() }
        } label: {
            Text(verbatim: "LVF").font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(model.held ? Color.black : Color.primary)
                .fixedSize().rotationEffect(turn).frame(width: 52, height: 52)
                .background { if model.held { Circle().fill(Color.accentColor) } }
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(model.busy || !(ready || model.held))
        .accessibilityLabel(
            model.held
                ? String(localized: "camera.resume", defaultValue: "Resume Camera")
                : String(localized: "camera.hold", defaultValue: "Hold Camera")
        )
        .accessibilityAddTraits(model.held ? .isSelected : [])
        .accessibilityIdentifier("camera.hold")
    }

    private var libraryButton: some View {
        Button(action: onLibrary) {
            Group {
                if let photo = model.library.photos.last {
                    PhotoThumbnail(photo: photo, images: model.library.images, showsBadges: false)
                } else {
                    Image(systemName: "photo.on.rectangle")
                }
            }
            .rotationEffect(turn).frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.3), lineWidth: 1) }
            // How many captures this session has added to the library.
            .overlay(alignment: .topTrailing) {
                if model.savedCount > 0 {
                    Text(verbatim: "\(model.savedCount)")
                        .font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(.black)
                        .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                        .background(Color.accentColor, in: .capsule).offset(x: 7, y: -7)
                        .accessibilityLabel(
                            String(
                                localized: "camera.saved_to_library",
                                defaultValue: "Saved to Library: \(model.savedCount)")
                        )
                        .accessibilityIdentifier("camera.saved")
                }
            }
        }
        .buttonStyle(.plain).disabled(model.busy)
        .accessibilityLabel(String(localized: "camera.open_library", defaultValue: "Open Library"))
        .accessibilityIdentifier("camera.library")
    }

    private var shutterButton: some View {
        Button {
            Task { await model.takePhoto() }
        } label: {
            Color.clear.frame(width: 78, height: 78)
        }
        .buttonStyle(ShutterStyle(busy: model.busy, animates: !reduceMotion))
        // On hold, the shutter wakes the camera.
        .disabled(!(model.canCapture || model.held))
        .accessibilityLabel(String(localized: "camera.take_raw_photo", defaultValue: "Take RAW Photo"))
        .accessibilityIdentifier("camera.shutter")
    }

    private var megapixels: Int {
        model.format == .proRAW && model.highResolution ? model.maximumMegapixels : 12
    }
    // Bayer RAW dimensions come from the sensor, not a universal 12 MP promise.
    private var formatSummary: String { model.format == .proRAW ? "PRO \(megapixels)" : "RAW" }
    @ViewBuilder private var formatControl: some View {
        if !model.formats.isEmpty {
            Menu {
                if model.formats.count > 1 {
                    Picker(
                        String(localized: "camera.raw_format", defaultValue: "RAW Format"),
                        selection: $model.format
                    ) {
                        ForEach(model.formats) { Text($0.title).tag($0) }
                    }
                }
                if model.maximumMegapixels > 12 && model.format == .proRAW {
                    Picker(
                        String(localized: "camera.resolution", defaultValue: "Resolution"),
                        selection: Binding(
                            get: { model.highResolution },
                            set: { value in Task { await model.setHighResolution(value) } }
                        )
                    ) {
                        Text(String(localized: "camera.12_mp", defaultValue: "12 MP")).tag(false)
                        Text(
                            String(
                                localized: "camera.max_mp",
                                defaultValue: "Max (\(model.maximumMegapixels) MP)")
                        ).tag(true)
                    }
                }
            } label: {
                Text(verbatim: formatSummary).font(.caption.weight(.semibold)).monospacedDigit()
            }
            .disabled(model.busy).accessibilityIdentifier("camera.format")
            .accessibilityLabel(model.format == .proRAW ? model.format.title + ", \(megapixels) MP" : model.format.title)
        } else {
            Text("DNG").font(.caption.weight(.semibold)).accessibilityLabel(
                String(localized: "camera.dng_raw", defaultValue: "DNG RAW"))
        }
    }
}

private struct CameraShutterBounds: PreferenceKey {
    nonisolated static var defaultValue: Anchor<CGRect>? { nil }
    nonisolated static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// What the viewfinder shows while the camera is off: one screen for a user hold and for every
/// system interruption. Only a hold can be ended by tapping.
private struct CameraHoldScreen: View {
    let held: Bool
    let reason: String?
    var turn = Angle.zero
    let resume: () -> Void
    var body: some View {
        Button(action: resume) {
            ZStack {
                // A flat, dim surface: no live pixels, and little for the display to light.
                Color(white: 0.13)
                VStack(spacing: 14) {
                    Image(systemName: "viewfinder").font(.system(size: 44, weight: .ultraLight))
                        .overlay {
                            Rectangle().fill(.secondary).frame(width: 60, height: 1.5)
                                .rotationEffect(.degrees(-45))
                        }
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(spacing: 5) {
                        Text(String(localized: "camera.on_hold", defaultValue: "Camera on Hold"))
                            .font(.headline)
                        Text(
                            held
                                ? String(
                                    localized: "camera.hold_power_note",
                                    defaultValue: "The sensor and preview are off to save power.")
                                : reason
                                    ?? String(
                                        localized: "camera.interrupted.generic",
                                        defaultValue: "The camera will resume when it is available.")
                        )
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if held {
                        Text(String(localized: "camera.hold_hint", defaultValue: "Tap to resume"))
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.white.opacity(0.1), in: .capsule)
                    }
                }
                .frame(maxWidth: 260).rotationEffect(turn)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(!held)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("camera.hold.screen")
    }
}

/// A round glass control around the viewfinder.
private struct CameraRoundControl: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: .circle).contentShape(.circle)
    }
}

private struct LensSegment: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        content
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(minWidth: 40, minHeight: 36).padding(.horizontal, 2)
            .background { if selected { Capsule().fill(.white.opacity(0.16)) } }
            .contentShape(.capsule)
    }
}

/// A ring with a disc that gives under the finger and dims while a capture is in flight.
private struct ShutterStyle: ButtonStyle {
    let busy: Bool
    let animates: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 4)
                    Circle().fill(.white).padding(7)
                        .scaleEffect(configuration.isPressed ? 0.86 : 1)
                        .opacity(busy ? 0.45 : 1)
                }
            }
            .opacity(enabled ? 1 : 0.35)
            .animation(animates ? .snappy(duration: 0.15) : nil, value: configuration.isPressed)
            .contentShape(.circle)
    }
}

private struct CameraActionKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var openCamera: (() -> Void)? {
        get { self[CameraActionKey.self] }
        set { self[CameraActionKey.self] = newValue }
    }
}
