import SwiftUI
import UIKit

@main
struct SpektraCamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            ContentView().appAccent()
        }
    }
}

/// The camera keeps its controls where the hands learned them: while it is open on an iPhone
/// the interface stays upright and only the glyphs turn, as in the system camera.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask?

    func application(
        _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationLock ?? (UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown)
    }

    /// Ask the system to hold the interface in portrait, or release it. The system may refuse:
    /// iPad multitasking and iPhone Duo's inner display do not take orientation requests.
    /// `refused` is then called, and the caller keeps its adaptive layout. Never infer the
    /// outcome from the device model or its orientation; this callback is the only answer.
    static func lockPortrait(_ locked: Bool, refused: @escaping @MainActor () -> Void = {}) {
        orientationLock = locked ? .portrait : nil
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: locked ? .portrait : .all)) { _ in
                Task { @MainActor in
                    if locked { orientationLock = nil }
                    refused()
                }
            }
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}
