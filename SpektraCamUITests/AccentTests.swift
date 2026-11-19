import XCTest

/// The accent chosen in About applies at once, in the sheet and behind it. Set
/// `SPEKTRACAM_LAYOUT_PHOTO` to a host image to also tour the editor in each accent, and
/// `SPEKTRACAM_LAYOUT_SHOTS` to a host directory for screenshots.
final class AccentTests: XCTestCase {
    private var shots: String? { ProcessInfo.processInfo.environment["SPEKTRACAM_LAYOUT_SHOTS"] }
    private var photo: String? { ProcessInfo.processInfo.environment["SPEKTRACAM_LAYOUT_PHOTO"] }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: shots + "/" + name + ".png"))
        }
    }
    @MainActor private func choose(_ accent: String, in app: XCUIApplication) {
        app.buttons["library.info"].tap()
        let swatch = app.buttons["about.accent." + accent]
        XCTAssertTrue(swatch.waitForExistence(timeout: 5))
        swatch.tap()
        XCTAssertTrue(swatch.isSelected, accent + " was not selected")
        for other in ["magenta", "orange", "blue", "mono"] where other != accent {
            XCTAssertFalse(app.buttons["about.accent." + other].isSelected)
        }
    }

    @MainActor func testAccentChoiceAppliesAndPersists() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = ["--ui-test-library", "--reset-test-library"]
        if let photo { app.launchArguments += ["--ui-test-import", photo] }
        app.launch()
        XCTAssertTrue(app.buttons["library.info"].waitForExistence(timeout: 20))
        addTeardownBlock { @MainActor in
            guard app.state == .runningForeground else { return }
            if !app.buttons["library.info"].exists { app.terminate(); app.launch() }
            app.buttons["library.info"].tap()
            if app.buttons["about.accent.magenta"].waitForExistence(timeout: 5) {
                app.buttons["about.accent.magenta"].tap()
            }
        }
        for accent in ["orange", "blue", "mono"] {
            let name = accent
            choose(accent, in: app)
            capture(app, name + "-about")
            app.buttons["Done"].tap()
            capture(app, name + "-library")
            guard photo != nil else { continue }
            let cell = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'")).firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 30))
            app.buttons["library.select"].tap()
            cell.tap()
            capture(app, name + "-selection")
            app.buttons["library.select"].tap()
            cell.tap()
            XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
            capture(app, name + "-viewer")
            app.buttons["photo.develop"].tap()
            XCTAssertTrue(app.buttons["editor.tool.develop"].waitForExistence(timeout: 30))
            if !app.buttons["develop.mode.spektrafilm"].waitForExistence(timeout: 3) {
                app.buttons["editor.tool.develop"].tap()
            }
            XCTAssertTrue(app.buttons["develop.mode.spektrafilm"].waitForExistence(timeout: 5))
            app.buttons["develop.mode.spektrafilm"].tap()
            sleep(2)
            capture(app, name + "-develop")
            app.buttons["editor.tool.adjust"].tap()
            XCTAssertTrue(app.sliders["tone.exposure"].waitForExistence(timeout: 5))
            capture(app, name + "-adjust")
            app.buttons["editor.export"].tap()
            XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
            capture(app, name + "-darkroom")
            // A relaunch reads the stored choice; the library is the same on return.
            app.terminate()
            app.launchArguments = ["--ui-test-library"]
            app.launch()
            XCTAssertTrue(app.buttons["library.info"].waitForExistence(timeout: 20))
            app.buttons["library.info"].tap()
            XCTAssertTrue(app.buttons["about.accent." + accent].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["about.accent." + accent].isSelected, accent + " was not restored")
            app.buttons["Done"].tap()
        }
    }
}
