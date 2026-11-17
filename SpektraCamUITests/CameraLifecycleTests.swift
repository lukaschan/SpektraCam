import UIKit
import XCTest

/// Run unchanged on phone, Duo (both displays), and iPad (full screen and windowed).
final class CameraLifecycleTests: XCTestCase {
    @MainActor func testPortraitRoundTrip() throws { try roundTrip(.portrait) }
    @MainActor func testLandscapeRoundTrip() throws { try roundTrip(.landscapeLeft) }

    @MainActor private func roundTrip(_ orientation: UIDeviceOrientation) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        // Odd dimensions exercise partial GPU groups in thumbnails, previews, and grading.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 517, height: 337), format: format)
            .image { context in
                UIColor.gray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 517, height: 337))
                UIColor.orange.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 259, height: 169))
            }
        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("camera-round-trip.png")
        try XCTUnwrap(image.pngData()).write(to: photo)
        defer { try? FileManager.default.removeItem(at: photo) }
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = [
            "--ui-test-library", "--reset-test-library", "--ui-test-camera-demo",
            "--ui-test-import", photo.path,
        ]
        app.launch()
        let cell = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30))
        for useLibraryButton in [false, true] {
            app.buttons["camera.open"].tap()
            let shutter = app.buttons["camera.shutter"]
            XCTAssertTrue(app.buttons["camera.lens.24"].waitForExistence(timeout: 10))
            XCTAssertTrue(shutter.isEnabled)
            let window = app.windows.firstMatch.frame
            if window.width > window.height && window.width >= 560 {
                XCTAssertEqual(shutter.frame.midY, window.midY, accuracy: 1, "Landscape shutter is off center")
            } else {
                XCTAssertEqual(shutter.frame.midX, window.midX, accuracy: 1, "Portrait shutter is off center")
            }
            let flash = app.buttons["camera.flash"].frame
            let flip = app.buttons["camera.flip"].frame
            XCTAssertEqual(app.buttons["camera.lens.24"].frame.midY, flash.midY, accuracy: 1)
            XCTAssertEqual(flip.midY, flash.midY, accuracy: 1)
            app.buttons["camera.hold"].tap()
            let hold = app.descendants(matching: .any)["camera.hold.screen"]
            XCTAssertTrue(hold.waitForExistence(timeout: 5))
            if !useLibraryButton {
                XCUIDevice.shared.press(.home)
                app.activate()
                XCTAssertTrue(hold.waitForExistence(timeout: 5), "Foregrounding ended a user hold")
            }
            shutter.tap()
            XCTAssertTrue(hold.waitForNonExistence(timeout: 5))
            XCTAssertTrue(shutter.isEnabled)
            XCUIDevice.shared.orientation = orientation.isLandscape ? .portrait : .landscapeLeft
            app.buttons[useLibraryButton ? "camera.library" : "camera.close"].tap()
            XCTAssertTrue(app.buttons["camera.close"].waitForNonExistence(timeout: 10))
            // A visible or hittable library is insufficient: prove that a real action works.
            app.buttons["library.info"].tap()
            let about = app.navigationBars["About"]
            XCTAssertTrue(about.waitForExistence(timeout: 5))
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
            XCTAssertTrue(about.waitForNonExistence(timeout: 5))
        }
        cell.tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        app.buttons["photo.develop"].tap()
        let film = app.buttons["develop.mode.spektrafilm"]
        XCTAssertTrue(film.waitForExistence(timeout: 30))
        film.tap()
        let preview = app.images["Edited photo"]
        XCTAssertTrue(preview.waitForExistence(timeout: 30))
        XCTAssertTrue(app.activityIndicators["Rendering preview"].waitForNonExistence(timeout: 30))
        app.buttons["editor.tool.adjust"].tap()
        let slider = app.sliders["tone.exposure"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        slider.adjust(toNormalizedSliderPosition: 0.6)
        XCTAssertTrue(app.activityIndicators["Rendering preview"].waitForNonExistence(timeout: 30))
        // Dismiss from inside the editor too; its navigation state must survive the camera.
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.close"].waitForExistence(timeout: 10))
        app.buttons["camera.close"].tap()
        XCTAssertTrue(app.buttons["camera.close"].waitForNonExistence(timeout: 10))
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 15))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Camera returned to a working rendered photo"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func testBayerOnlyCamera() {
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = ["--ui-test-library", "--reset-test-library", "--ui-test-camera-demo", "--ui-test-camera-bayer-only"]
        app.launch()
        XCTAssertTrue(app.buttons["camera.open"].waitForExistence(timeout: 15))
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.lens.24"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["camera.lens.120"].exists)
        XCTAssertFalse(app.buttons["camera.lens.13"].exists)
        XCTAssertFalse(app.buttons["camera.flip"].isEnabled)
        XCTAssertTrue(app.buttons["camera.format"].label.contains("Bayer RAW"))
        app.buttons["camera.lens.120"].tap()
        XCTAssertTrue(app.buttons["camera.lens.120"].isSelected)
        app.buttons["camera.close"].tap()
        XCTAssertTrue(app.buttons["library.info"].waitForExistence(timeout: 10))
    }

    @MainActor func testNoRAWCameraKeepsLibraryAvailable() {
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = ["--ui-test-library", "--reset-test-library", "--ui-test-camera-demo", "--ui-test-camera-no-raw"]
        app.launch()
        XCTAssertTrue(app.buttons["camera.open"].waitForExistence(timeout: 15))
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["camera.rawUnsupported"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["camera.shutter"].isEnabled)
        XCTAssertFalse(app.buttons["camera.flip"].isEnabled)
        app.buttons["camera.close"].tap()
        app.buttons["library.info"].tap()
        XCTAssertTrue(app.buttons["about.importFiles"].waitForExistence(timeout: 10))
    }
}
