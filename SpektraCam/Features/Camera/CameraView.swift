import SwiftUI

struct CameraView: View {
    @State private var model: CameraModel
    let onLibrary: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    private let cameraButtonSize: CGFloat = 44
    private let bubbleDiameter: CGFloat = 38
    init(library: PhotoLibrary, onLibrary: @escaping () -> Void) {
        _model = State(initialValue: CameraModel(library: library))
        self.onLibrary = onLibrary
    }
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                CameraViewfinder(model: model)
                if model.state == .ready {
                    VStack {
                        Spacer()
                        lensControls.padding(.horizontal).padding(.bottom, 48)
                    }
                }
                if model.state != .ready { status }
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
                }
                ToolbarItem(placement: .topBarTrailing) {
                    CameraExposureReadout(model: model).frame(width: 84, height: 32)
                        .accessibilityIdentifier("camera.exposureInfo")
                }.sharedBackgroundVisibility(.visible)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if model.state == .ready {
                        CameraExposureControl(value: Binding(get: { model.exposureBias }, set: model.setExposureBias),
                            range: model.exposureRange).disabled(model.busy).padding(.horizontal, 24)
                    }
                    if let failure = model.saveFailure {
                        VStack(spacing: 8) {
                            Text(failure).font(.footnote)
                            if model.pendingCount > 0 {
                                Text(
                                    String(
                                        localized: "camera.the_capture_is_kept_on_this_iphone",
                                        defaultValue: "The capture is kept on this iPhone.")
                                ).font(.footnote)
                                Button(
                                    String(
                                        localized: "camera.retry_import",
                                        defaultValue: "Retry Import")
                                ) { Task { await model.retryImport() } }
                                .buttonStyle(.glass).disabled(model.busy)
                                .accessibilityIdentifier("camera.retryImport")
                            }
                        }.padding().glassEffect(in: .rect(cornerRadius: 20))
                    }
                    ZStack {
                        HStack {
                            Button {
                                onLibrary()
                            } label: {
                                if let photo = model.library.photos.last {
                                    PhotoThumbnail(
                                        photo: photo, images: model.library.images,
                                        showsBadges: false
                                    )
                                    .frame(width: cameraButtonSize, height: cameraButtonSize)
                                    .clipShape(
                                        .circle)
                                } else {
                                    Image(systemName: "photo.on.rectangle").frame(
                                        width: cameraButtonSize, height: cameraButtonSize)
                                }
                            }
                            .buttonStyle(.glass).buttonBorderShape(.circle).disabled(model.busy)
                            .accessibilityLabel(
                                String(
                                    localized: "camera.open_library", defaultValue: "Open Library")
                            ).accessibilityIdentifier(
                                "camera.library")
                            Spacer()
                            Button {
                                Task { await model.flip() }
                            } label: {
                                cameraBubble(
                                    Image(systemName: "arrow.triangle.2.circlepath.camera").font(
                                        .system(size: 16)))
                            }
                            .labelStyle(.iconOnly).buttonStyle(.plain)
                            .accessibilityLabel(
                                String(localized: "camera.flip_camera", defaultValue: "Flip Camera")
                            )
                            .disabled(model.busy || !model.lenses.contains(where: \.front))
                            .accessibilityIdentifier("camera.flip")
                        }
                        Button {
                            Task { await model.takePhoto() }
                        } label: {
                            Image(systemName: "circle.inset.filled")
                                .font(.system(size: 58, weight: .regular)).frame(
                                    width: 76, height: 76)
                        }
                        .buttonStyle(.glass).buttonBorderShape(.circle).tint(.white)
                        .disabled(!model.canCapture)
                        .accessibilityLabel(
                            String(
                                localized: "camera.take_raw_photo", defaultValue: "Take RAW Photo")
                        ).accessibilityIdentifier(
                            "camera.shutter"
                        )
                        .overlay { if model.busy { ProgressView().allowsHitTesting(false) } }
                    }
                    Text(
                        model.savedCount > 0
                            ? String(
                                localized: "camera.saved_to_library",
                                defaultValue: "Saved to Library: \(model.savedCount)")
                            : String(
                                localized: "camera.raw_photos_save_to_the_app_library",
                                defaultValue: "RAW photos save to the app library.")
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("camera.saved")
                }.padding(.horizontal).padding(.bottom, 12)
            }
        }
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
        .onDisappear { Task { await model.close() } }
    }
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
                if model.maximumMegapixels > 12 {
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
                Text("DNG").font(.caption.weight(.semibold))
            }
            .disabled(model.busy).accessibilityIdentifier("camera.format")
            .accessibilityLabel("DNG, " + model.format.title)
        } else {
            Text("DNG").font(.caption.weight(.semibold)).accessibilityLabel(
                String(localized: "camera.dng_raw", defaultValue: "DNG RAW"))
        }
    }
    private var lensControls: some View {
        GlassEffectContainer(spacing: 8) {
            ZStack(alignment: .leading) {
                if model.selectedLens?.front != true && model.lenses.contains(where: \.macro) {
                    Button {
                        Task { await model.toggleMacro() }
                    } label: {
                        cameraBubble(Image(systemName: "camera.macro").font(.system(size: 16)))
                    }
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "camera.macro", defaultValue: "Macro"))
                    .foregroundStyle(model.macro ? Color.accentColor : .primary)
                    .accessibilityAddTraits(model.macro ? .isSelected : [])
                    .accessibilityIdentifier("camera.macro")
                }
                HStack(spacing: 6) {
                    ForEach(model.lenses.filter { !$0.front && model.selectedLens?.front != true })
                    { lens in
                        Button {
                            Task { await model.selectLens(lens) }
                        } label: {
                            cameraBubble(
                                Text(lens.title).font(.system(size: 13, weight: .semibold))
                                    .monospacedDigit())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(
                            lens.id == model.selectedLens?.id ? Color.accentColor : .primary
                        )
                        .accessibilityAddTraits(
                            lens.id == model.selectedLens?.id ? .isSelected : []
                        )
                        .accessibilityIdentifier("camera.lens.\(lens.millimeters)")
                        .accessibilityLabel(
                            lens.front
                                ? String(
                                    localized: "camera.front_camera", defaultValue: "Front camera")
                                : String(
                                    localized: "camera.millimeter_lens",
                                    defaultValue: "\(lens.millimeters) millimeter lens"))
                    }
                }.frame(maxWidth: .infinity)
            }.frame(height: cameraButtonSize).disabled(model.busy).dynamicTypeSize(
                ...DynamicTypeSize.xxxLarge)
        }
    }
    private func cameraBubble<Content: View>(_ content: Content) -> some View {
        content.frame(width: bubbleDiameter, height: bubbleDiameter)
            .glassEffect(.regular.interactive(), in: .circle)
            .frame(width: cameraButtonSize, height: cameraButtonSize).contentShape(.circle)
    }
    @ViewBuilder private var status: some View {
        switch model.state {
        case .ready: EmptyView()
        case .starting:
            ProgressView(
                String(localized: "camera.starting_camera", defaultValue: "Starting camera…"))
        case .unavailable:
            ContentUnavailableView(
                String(localized: "camera.camera_unavailable", defaultValue: "Camera Unavailable"),
                systemImage: "camera",
                description: Text(
                    String(
                        localized: "camera.raw_capture_needs_a_physical_iphone",
                        defaultValue: "RAW capture needs a physical iPhone."))
            )
            .accessibilityIdentifier("camera.unavailable")
        case .denied:
            ContentUnavailableView {
                Label(
                    String(localized: "camera.camera_access", defaultValue: "Camera Access"),
                    systemImage: "camera")
            } description: {
                Text(
                    String(
                        localized: "camera.allow_camera_access_in_settings_to_take",
                        defaultValue: "Allow camera access in Settings to take photos."))
            } actions: {
                Button(String(localized: "camera.open_settings", defaultValue: "Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.buttonStyle(.glass)
            }
        case .paused:
            ContentUnavailableView(
                String(localized: "camera.camera_paused", defaultValue: "Camera Paused"),
                systemImage: "camera",
                description: Text(
                    model.pauseReason
                        ?? String(
                            localized: "camera.the_camera_will_resume_when_it_is",
                            defaultValue: "The camera will resume when it is available.")))
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
}

private struct CameraActionKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var openCamera: (() -> Void)? {
        get { self[CameraActionKey.self] }
        set { self[CameraActionKey.self] = newValue }
    }
}
