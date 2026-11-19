import XCTest

/// Save a look as a formula, apply it from the viewer and to a selection, and manage it.
/// Set `SPEKTRACAM_LAYOUT_PHOTO` and `SPEKTRACAM_SECOND_PHOTO` to two different host images,
/// and optionally `SPEKTRACAM_LAYOUT_SHOTS` to a host directory for screenshots.
final class FormulaTests: XCTestCase {
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

    @MainActor func testSaveApplyAndManageFormula() throws {
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

        // An empty manager says how to make a formula.
        app.buttons["library.formulae"].tap()
        XCTAssertTrue(app.staticTexts["No Formulae"].waitForExistence(timeout: 5))
        capture(app, "formula-manager-empty")
        app.buttons["formula.library.close"].tap()

        // Develop one photo and save its look.
        cells(app).element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["develop.mode.spektrafilm"].waitForExistence(timeout: 30))
        app.buttons["develop.mode.spektrafilm"].tap()
        sleep(2)
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 20))
        app.buttons["photo.info"].tap()
        let saveAs = app.buttons["photo.formula.save"]
        XCTAssertTrue(saveAs.waitForExistence(timeout: 5))
        saveAs.tap()
        let name = app.textFields["formula.save.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["formula.save.confirm"].isEnabled, "A formula needs a name")
        name.tap()
        name.typeText("Tree test")
        XCTAssertEqual(app.switches["formula.save.part.look"].value as? String, "1")
        XCTAssertEqual(app.switches["formula.save.part.exposure"].value as? String, "0")
        capture(app, "formula-save-sheet")
        app.buttons["formula.save.confirm"].tap()
        let tile = app.buttons["photo.formula.Tree test"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        sleep(3)
        capture(app, "formula-viewer-strip")
        app.buttons["photo.info"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["library.select"].waitForExistence(timeout: 10))
        waitForEdited(1, in: app)

        // Apply it to a selection, then take it back.
        app.buttons["library.select"].tap()
        cells(app).element(boundBy: 0).tap()
        cells(app).element(boundBy: 1).tap()
        app.buttons["library.look"].tap()
        let applyMenu = app.buttons["Apply Formula"]
        XCTAssertTrue(applyMenu.waitForExistence(timeout: 5))
        applyMenu.tap()
        XCTAssertTrue(app.buttons["Tree test"].waitForExistence(timeout: 5))
        capture(app, "formula-apply-menu")
        app.buttons["Tree test"].tap()
        waitForEdited(2, in: app)
        XCTAssertTrue(app.buttons["library.look.undo"].waitForExistence(timeout: 5))
        sleep(3)
        capture(app, "formula-library-applied")
        app.buttons["library.look.undo"].tap()
        waitForEdited(1, in: app)
        app.buttons["library.select"].tap()

        // In the viewer one tap applies it to the untouched photo.
        let untouched = cells(app).allElementsBoundByIndex.first { $0.value as? String == "Original" }
        try XCTUnwrap(untouched).tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        app.buttons["photo.info"].tap()
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["photo.formula.save"].isEnabled, "An untouched photo has no look to save")
        sleep(3)
        capture(app, "formula-viewer-preview")
        tile.tap()
        XCTAssertTrue(app.buttons["photo.look.undo"].waitForExistence(timeout: 10))
        app.buttons["photo.info"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["library.select"].waitForExistence(timeout: 10))
        waitForEdited(2, in: app)

        // Manage: the formula is listed; rename it; it survives a restart; delete it.
        app.buttons["library.formulae"].tap()
        let row = app.buttons["formula.row.Tree test"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        capture(app, "formula-manager")
        row.tap()
        // A formula has its own page: what it carries, sharing, and Rename.
        XCTAssertTrue(app.buttons["formula.share"].waitForExistence(timeout: 5))
        capture(app, "formula-detail")
        app.buttons["formula.detail.rename"].tap()
        let alert = app.alerts.firstMatch
        if !alert.waitForExistence(timeout: 5) { capture(app, "formula-rename-missing") }
        XCTAssertTrue(alert.exists)
        let rename = alert.textFields.element(boundBy: 0)
        rename.tap()
        rename.typeText(" 2")
        capture(app, "formula-rename")
        alert.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Tree test 2"].waitForExistence(timeout: 5))
        app.navigationBars["Tree test 2"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["formula.row.Tree test 2"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-test-library"]
        app.launch()
        XCTAssertTrue(app.buttons["library.formulae"].waitForExistence(timeout: 20))
        app.buttons["library.formulae"].tap()
        XCTAssertTrue(app.buttons["formula.row.Tree test 2"].waitForExistence(timeout: 5), "Restart lost the formula")
        app.buttons["formula.library.select"].tap()
        app.staticTexts["Tree test 2"].tap()
        app.buttons["formula.delete"].tap()
        app.buttons["Delete Formulae"].tap()
        XCTAssertTrue(app.staticTexts["No Formulae"].waitForExistence(timeout: 5))
        app.buttons["formula.library.close"].tap()
        waitForEdited(2, in: app)
    }
}
