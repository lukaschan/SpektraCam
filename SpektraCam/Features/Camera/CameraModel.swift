import Foundation
import Observation
import UIKit

@MainActor @Observable final class CameraModel {
    enum State: Equatable {
        case starting, ready, paused, denied, unavailable, rawUnsupported
        case failed(String)
    }
    private(set) var state = State.starting
    private(set) var source: CameraPreviewSource?
    private(set) var formats: [CameraFormat] = []
    var format = CameraFormat.proRAW
    private(set) var busy = false
    private(set) var outputReady = false
    private(set) var savedCount = 0
    private(set) var saveFailure: String?
    private(set) var pendingCount = 0
    private let service = CameraService()
    let library: PhotoLibrary
    private(set) var readings = CameraReadings()
    private(set) var lenses: [CameraLens] = []
    private(set) var selectedLens: CameraLens?
    private(set) var macro = false
    private(set) var highResolution = false
    private(set) var maximumMegapixels = 12
    private(set) var pauseReason: String?
    private(set) var exposureBias = 0.0
    private(set) var exposureRange: ClosedRange<Double> = -3...3
    /// LVF hold: the user switched the camera off to save power. Only the user ends it.
    private(set) var held = false
    private(set) var flashAvailable = false
    static let rememberFlashKey = "camera.rememberFlash"
    private static let flashKey = "camera.flashOn"
    var flashOn = false {
        didSet {
            if UserDefaults.standard.bool(forKey: Self.rememberFlashKey) {
                UserDefaults.standard.set(flashOn, forKey: Self.flashKey)
            }
        }
    }
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var biasSetAt = Date.distantPast
    private let location = CameraLocation()
    private var beforeMacro: String?
    private var backLens: String?
    private var wantsActive = false
    private var starting = false
    private var closed = false
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    init(library: PhotoLibrary) {
        self.library = library
        if UserDefaults.standard.bool(forKey: Self.rememberFlashKey) {
            flashOn = UserDefaults.standard.bool(forKey: Self.flashKey)
        }
    }
    /// A capture is possible again as soon as its file is written; importing does not block it.
    /// Only a failed import with captures still waiting holds the shutter.
    var canCapture: Bool {
        !closed && wantsActive && !held && state == .ready && outputReady && !busy
            && (saveFailure == nil || pendingCount == 0)
    }
    var canFlip: Bool {
        guard let selectedLens else { return false }
        return lenses.contains { $0.front != selectedLens.front }
    }
    func toggleHold() async {
        guard !closed, wantsActive, !busy, state == .ready || held else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        if held {
            held = false
            await setActive(true)
        } else {
            held = true
            pauseReason = nil
            location.setActive(false)
            state = .paused
            await service.stop()
        }
    }
    func setActive(_ active: Bool) async {
        guard !closed else { return }
        wantsActive = active
        // Returning to the app does not undo a hold; the user asked for the camera to stay off.
        if active && held {
            state = .paused
            return
        }
        #if DEBUG && targetEnvironment(simulator)
            if active && Self.demo {
                applyDemo()
                return
            }
        #endif
        if !active {
            location.setActive(false)
            state = .paused
            await service.stop()
            return
        }
        guard !starting else { return }
        starting = true
        defer { starting = false }
        state = .starting
        do {
            let configuration = try await service.start()
            guard !closed else { return }
            apply(configuration)
            if wantsActive && !held {
                state = .ready
                pauseReason = nil
                location.setActive(true)
            } else {
                await service.stop()
            }
        } catch {
            guard wantsActive else {
                state = .paused
                return
            }
            switch error {
            case CameraFailure.denied: state = .denied
            case CameraFailure.unavailable: state = .unavailable
            case CameraFailure.rawUnavailable: state = .rawUnsupported
            default: state = .failed(error.localizedDescription)
            }
        }
    }
    func monitor() async {
        for await event in service.events {
            guard !Task.isCancelled, !closed else { return }
            switch event {
            case .readings(let value):
                readings = value
                // Camera Control changes the device directly; follow it once our own change settles.
                if Date().timeIntervalSince(biasSetAt) > 0.6,
                    abs(Double(value.bias) - exposureBias) > 0.02
                {
                    exposureBias = min(
                        max(Double(value.bias), exposureRange.lowerBound), exposureRange.upperBound)
                }
            case .ready(let ready): outputReady = ready
            case .interrupted(let reason):
                pauseReason = reason
                if wantsActive { state = .paused }
            case .resumed: if wantsActive && !held { await setActive(true) }
            case .failed(let message): if wantsActive { state = .failed(message) }
            }
        }
    }
    func takePhoto() async {
        guard !closed, wantsActive else { return }
        // The shutter wakes a held camera instead of failing silently.
        if held {
            await toggleHold()
            return
        }
        guard canCapture else { return }
        busy = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #if DEBUG && targetEnvironment(simulator)
            if Self.demo {
                try? await Task.sleep(for: .milliseconds(120))
                savedCount += 1
                busy = false
                return
            }
        #endif
        beginCaptureTask()
        do {
            _ = try await service.takePhoto(
                format: format, rotation: source?.captureRotation ?? 90,
                inbox: CameraInbox(root: library.files.root), location: location.captureLocation,
                flash: flashOn && flashAvailable)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            busy = false
            scheduleImport()
        } catch {
            saveFailure = error.localizedDescription
            busy = false
            endCaptureTask()
        }
    }
    /// The capture is already safe in the inbox. Import it behind the next shot, one at a time.
    private func scheduleImport() {
        let previous = importTask
        importTask = Task {
            await previous?.value
            do {
                savedCount += try await library.recoverCaptures()
                saveFailure = nil
            } catch { saveFailure = error.localizedDescription }
            pendingCount = (try? await library.files.pendingCaptures().count) ?? 0
            endCaptureTask()
        }
    }
    func retryImport() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            savedCount += try await library.recoverCaptures()
            saveFailure = nil
        } catch { saveFailure = error.localizedDescription }
        pendingCount = (try? await library.files.pendingCaptures().count) ?? 0
    }
    private func apply(_ configuration: CameraService.Configuration) {
        source = configuration.source
        formats = configuration.formats
        lenses = configuration.lenses
        selectedLens = configuration.selectedLens
        macro = configuration.macro
        highResolution = configuration.highResolution
        maximumMegapixels = configuration.maximumMegapixels
        exposureBias = configuration.exposureBias
        exposureRange = configuration.exposureRange
        flashAvailable = configuration.flashAvailable
        if !formats.contains(format), let first = formats.first { format = first }
    }
    func selectLens(_ lens: CameraLens, macro: Bool = false) async {
        guard !busy, state == .ready else { return }
        #if DEBUG && targetEnvironment(simulator)
            if Self.demo {
                selectedLens = lens
                self.macro = macro
                flashAvailable = !lens.front
                return
            }
        #endif
        busy = true
        defer { busy = false }
        do {
            apply(try await service.selectLens(lens.id, macro: macro))
            saveFailure = nil
            UISelectionFeedbackGenerator().selectionChanged()
        } catch { saveFailure = error.localizedDescription }
    }
    func setHighResolution(_ enabled: Bool) async {
        guard !busy, state == .ready else { return }
        busy = true
        defer { busy = false }
        do { apply(try await service.setHighResolution(enabled)) } catch {
            saveFailure = error.localizedDescription
        }
    }
    func focus(at point: CGPoint) async {
        guard state == .ready, !busy else { return }
        do {
            try await service.focus(at: point)
            UISelectionFeedbackGenerator().selectionChanged()
        } catch { saveFailure = error.localizedDescription }
    }
    func setExposureBias(_ value: Double) {
        guard state == .ready, !busy else { return }
        biasSetAt = Date()
        exposureBias = min(max(value, exposureRange.lowerBound), exposureRange.upperBound)
        #if DEBUG && targetEnvironment(simulator)
            if Self.demo { return }
        #endif
        let target = exposureBias
        Task {
            do { try await service.setExposureBias(target) } catch {
                saveFailure = error.localizedDescription
            }
        }
    }
    func toggleMacro() async {
        if macro {
            if let lens = lenses.first(where: { $0.id == beforeMacro }) { await selectLens(lens) }
        } else if let lens = lenses.first(where: \.macro) {
            beforeMacro = selectedLens?.id
            await selectLens(lens, macro: true)
        }
    }
    func flip() async {
        if selectedLens?.front == true {
            if let lens = lenses.first(where: { $0.id == backLens })
                ?? lenses.first(where: { !$0.front && $0.primary })
            {
                await selectLens(lens)
            }
        } else if let lens = lenses.first(where: \.front) {
            backLens = selectedLens?.id
            await selectLens(lens)
        }
    }
    private func beginCaptureTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save RAW Photo") { [weak self] in
            Task { @MainActor in self?.endCaptureTask() }
        }
    }
    private func endCaptureTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #if DEBUG && targetEnvironment(simulator)
        /// A stand-in camera for layout checks: every control is live, the viewfinder is empty.
        static let demo = ProcessInfo.processInfo.arguments.contains("--ui-test-camera-demo")
        private func applyDemo() {
            if ProcessInfo.processInfo.arguments.contains("--ui-test-camera-no-raw") {
                lenses = []
                formats = []
                outputReady = false
                state = .rawUnsupported
                return
            }
            let bayerOnly = ProcessInfo.processInfo.arguments.contains("--ui-test-camera-bayer-only")
            lenses = [
                CameraLens(id: "13", millimeters: 13, front: false, macro: true, primary: false),
                CameraLens(id: "24", millimeters: 24, front: false, macro: false, primary: true),
                CameraLens(id: "120", millimeters: 120, front: false, macro: false, primary: false),
                CameraLens(id: "front", millimeters: 23, front: true, macro: false, primary: false),
            ]
            if bayerOnly { lenses = lenses.filter { $0.primary || $0.id == "120" } }
            if selectedLens == nil { selectedLens = lenses.first(where: \.primary) }
            formats = bayerOnly ? [.bayerRAW] : CameraFormat.allCases
            if !formats.contains(format), let first = formats.first { format = first }
            maximumMegapixels = 48
            flashAvailable = selectedLens?.front != true
            outputReady = true
            readings = CameraReadings(
                histogram: (0..<64).map { exp(-pow(Double($0) - 26, 2) / 180) }, seconds: 1.0 / 250,
                aperture: 1.8, iso: 64, bias: Float(exposureBias))
            state = .ready
        }
    #endif
    func close() async {
        if !UserDefaults.standard.bool(forKey: Self.rememberFlashKey) {
            flashOn = false
            UserDefaults.standard.removeObject(forKey: Self.flashKey)
        }
        closed = true
        wantsActive = false
        outputReady = false
        state = .paused
        location.setActive(false)
        await service.shutdown()
    }
}
