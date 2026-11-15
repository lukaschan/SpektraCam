import XCTest

/// The editor and Darkroom follow the space they are given: stacked when taller than wide,
/// side by side when wider than tall. Runs on any Simulator; set
/// `SPEKTRACAM_LAYOUT_PHOTO` to a host image path and, optionally,
/// `SPEKTRACAM_LAYOUT_SHOTS` to a host directory for screenshots.
final class AdaptiveLayoutTests: XCTestCase {
    private var shots: String? { ProcessInfo.processInfo.environment["SPEKTRACAM_LAYOUT_SHOTS"] }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: shots + "/" + name + ".png"))
        }
    }

    @MainActor private func openEditor(_ orientation: UIDeviceOrientation) throws -> XCUIApplication {
        let photo = try XCTUnwrap(
            ProcessInfo.processInfo.environment["SPEKTRACAM_LAYOUT_PHOTO"],
            "Set SPEKTRACAM_LAYOUT_PHOTO to an image on the host")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = ["--ui-test-library", "--reset-test-library", "--ui-test-import", photo]
        app.launch()
        let cell = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30))
        capture(app, orientation.isLandscape ? "wide-library" : "tall-library")
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 10))
        capture(app, orientation.isLandscape ? "wide-camera" : "tall-camera")
        app.buttons["camera.close"].tap()
        cell.tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        capture(app, orientation.isLandscape ? "wide-viewer" : "tall-viewer")
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.tool.develop"].waitForExistence(timeout: 30))
        return app
    }

    @MainActor private func tour(_ app: XCUIApplication, prefix: String) {
        app.buttons["editor.tool.develop"].tap()
        XCTAssertTrue(app.buttons["develop.mode.spektrafilm"].waitForExistence(timeout: 5))
        app.buttons["develop.mode.spektrafilm"].tap()
        sleep(2)
        capture(app, prefix + "develop")
        app.buttons["editor.tool.adjust"].tap()
        XCTAssertTrue(app.sliders["tone.exposure"].waitForExistence(timeout: 5))
        capture(app, prefix + "adjust")
        app.buttons["editor.tool.effects"].tap()
        capture(app, prefix + "effects")
        app.buttons["editor.tool.crop"].tap()
        XCTAssertTrue(app.sliders["crop.straighten"].waitForExistence(timeout: 5))
        capture(app, prefix + "crop")
        app.buttons["crop.done"].tap()
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
        capture(app, prefix + "darkroom")
        app.buttons["darkroom.filmEdge"].tap()
        sleep(3)
        capture(app, prefix + "darkroom-edge")
    }

    @MainActor func testSideBySideWorkspaceInLandscape() throws {
        let app = try openEditor(.landscapeLeft)
        let window = app.windows.firstMatch.frame
        try XCTSkipIf(window.width <= window.height, "This device did not rotate to landscape")
        app.buttons["editor.tool.adjust"].tap()
        let slider = app.sliders["tone.exposure"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        let tools = EditorToolIDs.all.map { app.buttons[$0].frame }
        // Tools run top to bottom on the trailing edge, beside the controls, beside the photo.
        XCTAssertEqual(Set(tools.map { Int($0.midX) }).count, 1, "Tools are not in one column")
        XCTAssertEqual(tools.map(\.minY), tools.map(\.minY).sorted())
        XCTAssertGreaterThan(tools[0].minX, slider.frame.maxX)
        XCTAssertGreaterThan(slider.frame.minX, app.images["Edited photo"].frame.midX)
        XCTAssertFalse(app.buttons["editor.expand"].exists, "A full-height column has nothing to expand")
        // Section pills stay in a row above the controls.
        let pills = ["exposure", "liftGain", "color"].map { app.buttons["adjust.section." + $0].frame }
        XCTAssertEqual(pills.map(\.minX), pills.map(\.minX).sorted())
        XCTAssertLessThan(pills[0].maxY, slider.frame.minY)
        tour(app, prefix: "wide-")
    }

    @MainActor func testStackedWorkspaceInPortrait() throws {
        let app = try openEditor(.portrait)
        let window = app.windows.firstMatch.frame
        try XCTSkipIf(window.width >= window.height, "This device did not rotate to portrait")
        app.buttons["editor.tool.adjust"].tap()
        let slider = app.sliders["tone.exposure"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        let tools = EditorToolIDs.all.map { app.buttons[$0].frame }
        XCTAssertEqual(tools.map(\.minX), tools.map(\.minX).sorted())
        XCTAssertTrue(app.buttons["editor.expand"].exists)
        XCTAssertGreaterThan(slider.frame.minY, app.images["Edited photo"].frame.minY)
        tour(app, prefix: "tall-")
    }
}

private enum EditorToolIDs {
    static let all = ["crop", "develop", "adjust", "effects"].map { "editor.tool." + $0 }
}
