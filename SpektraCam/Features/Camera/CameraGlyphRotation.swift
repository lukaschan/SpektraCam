import Observation
import UIKit

/// How far to turn a glyph so it reads upright in the hand while the interface is held in
/// portrait. It is zero unless the caller confirms the hold: where the interface follows the
/// device, glyphs are already upright.
@MainActor @Observable final class CameraGlyphRotation {
    private(set) var degrees = 0.0
    @ObservationIgnored private var observer: NSObjectProtocol?

    func start() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
        // The first reading can arrive a moment after notifications are switched on.
        Task {
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(120))
                update()
            }
        }
    }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
    private func update() {
        switch UIDevice.current.orientation {
        case .portrait: degrees = 0
        case .landscapeLeft: degrees = 90
        case .landscapeRight: degrees = -90
        default: break  // Upside down, face up or face down: keep the last reading.
        }
    }
}
