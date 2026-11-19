import XCTest

/// Copy one photo's look, paste it to a selection, undo it, and paste inside the editor.
/// Set `SPEKTRACAM_LAYOUT_PHOTO` and `SPEKTRACAM_SECOND_PHOTO` to two different host images,
/// and optionally `SPEKTRACAM_LAYOUT_SHOTS` to a host directory for screenshots.
final class LookPasteTests: XCTestCase {
    private var shots: String? { ProcessInfo.processInfo.environment["SPEKTRACAM_LAYOUT_SHOTS"] }

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
    @MainActor private func cells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'"))
    }
    @MainActor private func edited(_ app: XCUIApplication) -> Int {
        cells(app).allElementsBoundByIndex.filter { $0.value as? String == "Edited" }.count
    }
    @MainActor private func waitForEdited(_ count: Int, in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(10)
        while edited(app) != count && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(edited(app), count)
    }

    @MainActor func testCopyPasteLookAndUndo() throws {
        let environment = ProcessInfo.processInfo.environment
        let first = try XCTUnwrap(environment["SPEKTRACAM_LAYOUT_PHOTO"], "Set SPEKTRACAM_LAYOUT_PHOTO")
        let second = try XCTUnwrap(environment["SPEKTRACAM_SECOND_PHOTO"], "Set SPEKTRACAM_SECOND_PHOTO")
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = [
            "--ui-test-library", "--reset-test-library", "--ui-test-import", first, "--ui-test-import", second,
        ]
        app.launch()
        XCTAssertTrue(cells(app).element(boundBy: 1).waitForExistence(timeout: 30))
        XCTAssertEqual(edited(app), 0)

        // Give one photo a film look; the editor saves it on the way out.
        cells(app).element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        app.buttons["photo.info"].tap()
        XCTAssertTrue(app.buttons["photo.look.copy"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["photo.look.copy"].isEnabled, "An untouched photo has no look to copy")
        XCTAssertFalse(app.buttons["photo.look.paste"].isEnabled)
        app.buttons["photo.info"].tap()
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["develop.mode.spektrafilm"].waitForExistence(timeout: 30))
        app.buttons["develop.mode.spektrafilm"].tap()
        sleep(2)
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 20))

        app.buttons["photo.info"].tap()
        XCTAssertTrue(app.buttons["photo.look.copy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["photo.look.copy"].isEnabled)
        app.buttons["photo.look.copy"].tap()
        XCTAssertTrue(app.buttons["photo.look.paste"].isEnabled)
        capture(app, "look-viewer-copied")
        app.buttons["photo.info"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["library.select"].waitForExistence(timeout: 10))
        waitForEdited(1, in: app)

        // Paste to both photos: only the untouched one changes.
        app.buttons["library.select"].tap()
        cells(app).element(boundBy: 0).tap()
        cells(app).element(boundBy: 1).tap()
        app.buttons["library.look"].tap()
        XCTAssertTrue(app.buttons["library.look.paste"].waitForExistence(timeout: 5))
        app.buttons["library.look.paste"].tap()
        let confirm = app.buttons["look.paste.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["look.paste.part.look"].value as? String, "1")
        XCTAssertEqual(app.switches["look.paste.part.exposure"].value as? String, "0")
        XCTAssertFalse(app.switches["look.paste.part.darkroom"].isEnabled, "The copied look has no Darkroom")
        capture(app, "look-paste-sheet")
        confirm.tap()
        let undo = app.buttons["library.look.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        waitForEdited(2, in: app)
        sleep(3)
        capture(app, "look-library-pasted")

        undo.tap()
        waitForEdited(1, in: app)
        XCTAssertFalse(undo.exists, "Undo stayed after it was used")
        sleep(2)
        capture(app, "look-library-undone")
        app.buttons["library.select"].tap()

        // Inside the editor a paste is one history step.
        let untouched = cells(app).allElementsBoundByIndex.first { $0.value as? String == "Original" }
        try XCTUnwrap(untouched).tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["develop.mode.spektrafilm"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["editor.info"].label.contains("Original"))
        app.buttons["editor.info"].tap()
        XCTAssertTrue(app.buttons["editor.look.paste"].waitForExistence(timeout: 5))
        capture(app, "look-editor-panel")
        app.buttons["editor.look.paste"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let named = NSPredicate(format: "NOT (label CONTAINS 'Original')")
        expectation(for: named, evaluatedWith: app.buttons["editor.info"])
        waitForExpectations(timeout: 10)
        sleep(2)
        capture(app, "look-editor-pasted")
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 20))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["library.select"].waitForExistence(timeout: 10))
        waitForEdited(2, in: app)
    }
}
