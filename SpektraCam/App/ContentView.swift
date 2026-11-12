import Combine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Open the app-owned library. A failed database open never resets the user's data.
struct ContentView: View {
    @State private var library: PhotoLibrary?
    @State private var failure: String?
    @State private var showCamera = false
    @State private var libraryPath: [UUID] = []
    @State private var libraryScrollRequest = 0
    @State private var captureImportFailure: String?
    @Environment(\.scenePhase) private var scenePhase
    private var checkingCameraControl: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains("--ui-test-camera-controls")
        #else
            false
        #endif
    }
    var body: some View {
        Group {
            if checkingCameraControl {
                #if DEBUG
                    CameraExposureControlPreview()
                #endif
            } else if let library {
                LibraryView(library: library, path: $libraryPath, scrollToLatestRequest: libraryScrollRequest)
                    .environment(\.openCamera, { showCamera = true })
                    .fullScreenCover(isPresented: $showCamera) {
                        CameraView(library: library) {
                            do { try library.flushForLibrary() } catch {
                                library.saveFailure = error.localizedDescription
                            }
                            libraryPath.removeAll()
                            libraryScrollRequest += 1
                            showCamera = false
                        }
                    }
                    .task {
                        await recoverCaptures(library)
                        try? await library.luts.load()
                        try? await library.repairRAWDimensions()
                        #if DEBUG || PERFORMANCE_CHECKS
                            await DarkroomOrientationChecks.run(library)
                            await RenderPerformanceChecks.run(library)
                            await ExportValidation.checkSDR(library)
                        #endif
                        #if DEBUG
                            await ExportValidation.checkBypass(library)
                            await ExportValidation.run(library)
                        #endif
                    }
            } else if let failure {
                ContentUnavailableView {
                    Label(
                        String(
                            localized: "app.couldn_t_open_library",
                            defaultValue: "Couldn’t open library"),
                        systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button(
                        String(localized: "common.retry", defaultValue: "Retry"),
                        action: openLibrary)
                }
            } else {
                ProgressView(
                    String(localized: "app.opening_library", defaultValue: "Opening library…"))
            }
        }
        .task { if !checkingCameraControl && library == nil { openLibrary() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            if let library {
                Task {
                    await library.images.discardMemory()
                    await library.files.discardPreparedPhoto()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                do { try library?.flushPending() } catch {
                    library?.saveFailure = error.localizedDescription
                }
            }
        }
        .alert(
            String(
                localized: "app.couldn_t_import_capture", defaultValue: "Couldn’t import capture"),
            isPresented: Binding(
                get: { captureImportFailure != nil },
                set: { if !$0 { captureImportFailure = nil } }
            )
        ) {
            Button(String(localized: "common.retry", defaultValue: "Retry")) {
                if let library { Task { await recoverCaptures(library) } }
            }
            Button(String(localized: "app.later", defaultValue: "Later"), role: .cancel) {}
        } message: {
            Text(
                String(
                    localized: "app.capture_kept_with_error",
                    defaultValue:
                        "The capture is kept on this iPhone. \(captureImportFailure ?? "")"))
        }
        .alert(
            String(localized: "app.couldn_t_save_edits", defaultValue: "Couldn’t save edits"),
            isPresented: Binding(
                get: { library?.saveFailure != nil },
                set: {
                    if !$0 { library?.saveFailure = nil }
                })
        ) {
            Button(String(localized: "common.retry", defaultValue: "Retry")) {
                do { try library?.flushPending() } catch {
                    library?.saveFailure = error.localizedDescription
                }
            }
        } message: {
            Text(library?.saveFailure ?? "")
        }
    }
    private func recoverCaptures(_ library: PhotoLibrary) async {
        do {
            try await library.recoverCaptures()
            captureImportFailure = nil
        } catch { captureImportFailure = error.localizedDescription }
    }
    private func openLibrary() {
        do {
            #if DEBUG && targetEnvironment(simulator)
                // UI checks use their own store. They cannot reset the user's app library.
                if ProcessInfo.processInfo.arguments.contains("--ui-test-library") {
                    let base = URL.applicationSupportDirectory.appendingPathComponent(
                        "SpektraCamUITests")
                    if ProcessInfo.processInfo.arguments.contains("--reset-test-library") {
                        try? FileManager.default.removeItem(at: base)
                    }
                    library = try PhotoLibrary(
                        root: base, cache: base.appendingPathComponent("Cache"))
                } else {
                    library = try PhotoLibrary()
                }
            #else
                library = try PhotoLibrary()
            #endif
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}

#Preview { ContentView() }
