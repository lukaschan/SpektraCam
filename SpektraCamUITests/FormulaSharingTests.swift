import CryptoKit
import XCTest

/// A formula file from someone else: previewed before it is added, refused while its LUT is
/// missing, linked by itself when the LUT arrives, and complete when the file carries the LUT.
/// Set `SPEKTRACAM_LAYOUT_PHOTO` to a host image, and optionally `SPEKTRACAM_LAYOUT_SHOTS`.
final class FormulaSharingTests: XCTestCase {
    private var shots: String? { ProcessInfo.processInfo.environment["SPEKTRACAM_LAYOUT_SHOTS"] }
    private let cube = "TITLE \"Warm Print\"\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0.9 0.8\n0 1 1\n1 1 0.9\n"
    private var lutID: String {
        SHA256.hash(data: Data(cube.utf8)).map { String(format: "%02x", $0) }.joined()
    }

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
    /// Files as another person's SpektraCam would send them.
    private func fixtures(carryingLUT: Bool) throws -> (formula: String, cube: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FormulaSharing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var file: [String: Any] = [
            "format": 1, "id": UUID().uuidString, "name": carryingLUT ? "Carried look" : "Shared look",
            "note": "From a friend", "created": "2026-11-16T00:00:00Z", "parts": ["look": 1],
            "recipe": [
                "look": [
                    "enabled": true, "mode": "lut", "first": ["id": lutID, "mix": 1], "second": ["mix": 0],
                ]
            ],
            "luts": [["id": lutID, "name": "Warm Print", "size": 2]],
        ]
        if carryingLUT { file["attachments"] = [["id": lutID, "name": "Warm Print", "cube": cube]] }
        let formula = folder.appendingPathComponent("Shared.rnformula")
        try JSONSerialization.data(withJSONObject: file).write(to: formula)
        let lut = folder.appendingPathComponent("Warm Print.cube")
        try Data(cube.utf8).write(to: lut)
        return (formula.path, lut.path)
    }
    @MainActor private func openFirstPhotoInformation(_ app: XCUIApplication) {
        let cell = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30))
        cell.tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        app.buttons["photo.info"].tap()
    }

    @MainActor func testFormulaWaitsForItsLUT() throws {
        let photo = try XCTUnwrap(
            ProcessInfo.processInfo.environment["SPEKTRACAM_LAYOUT_PHOTO"], "Set SPEKTRACAM_LAYOUT_PHOTO")
        let files = try fixtures(carryingLUT: false)
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = [
            "--ui-test-library", "--reset-test-library", "--ui-test-import", photo, "--ui-test-open", files.formula,
        ]
        app.launch()

        // The file is shown first. It says what it needs and adds nothing by itself.
        let add = app.buttons["formula.import.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Not installed"].exists)
        XCTAssertTrue(app.buttons["formula.lut.import"].exists)
        XCTAssertFalse(app.buttons["formula.lut.choose"].exists, "A file not yet added offered to change its LUT")
        capture(app, "sharing-import-missing")
        add.tap()

        app.buttons["library.formulae"].tap()
        let row = app.buttons["formula.row.Shared look"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        capture(app, "sharing-manager-missing")
        row.tap()
        XCTAssertTrue(app.buttons["formula.lut.choose"].waitForExistence(timeout: 5))
        capture(app, "sharing-detail-missing")
        // A formula can be passed on even while this device lacks its LUT.
        app.swipeUp()
        XCTAssertTrue(app.buttons["formula.share"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["formula.share.luts"].exists, "A LUT that is not installed was offered for sharing")
        app.navigationBars["Shared look"].buttons.element(boundBy: 0).tap()
        app.buttons["formula.library.close"].tap()

        // Without the LUT the formula is shown but cannot be applied.
        openFirstPhotoInformation(app)
        let tile = app.buttons["photo.formula.Shared look"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertFalse(tile.isEnabled, "A formula was offered without its LUT")
        capture(app, "sharing-viewer-missing")

        // The same LUT file arrives: the formula links to it by its contents, whatever its name.
        app.terminate()
        app.launchArguments = ["--ui-test-library", "--ui-test-lut", files.cube]
        app.launch()
        openFirstPhotoInformation(app)
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: tile)
        waitForExpectations(timeout: 10)
        tile.tap()
        XCTAssertTrue(app.buttons["photo.look.undo"].waitForExistence(timeout: 10))
        sleep(3)
        capture(app, "sharing-viewer-linked")

        // Opening the same file again says so instead of adding a copy.
        app.terminate()
        app.launchArguments = ["--ui-test-library", "--ui-test-open", files.formula]
        app.launch()
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["This formula is already in your library."].waitForExistence(timeout: 5))
        XCTAssertEqual(add.label, "Done")
        XCTAssertTrue(app.staticTexts["Installed"].exists)
        capture(app, "sharing-import-again")
        add.tap()
    }

    @MainActor func testFormulaCarryingItsLUT() throws {
        let photo = try XCTUnwrap(
            ProcessInfo.processInfo.environment["SPEKTRACAM_LAYOUT_PHOTO"], "Set SPEKTRACAM_LAYOUT_PHOTO")
        let files = try fixtures(carryingLUT: true)
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = [
            "--ui-test-library", "--reset-test-library", "--ui-test-import", photo, "--ui-test-open", files.formula,
        ]
        app.launch()
        let add = app.buttons["formula.import.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Included in this file"].exists)
        XCTAssertFalse(app.buttons["formula.lut.import"].exists)
        capture(app, "sharing-import-carried")
        add.tap()

        // The LUT went to the LUT library, and the formula applies at once.
        app.buttons["library.formulae"].tap()
        XCTAssertTrue(app.buttons["formula.row.Carried look"].waitForExistence(timeout: 5))
        app.buttons["formula.row.Carried look"].tap()
        XCTAssertTrue(app.buttons["formula.share.luts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Installed"].exists)
        capture(app, "sharing-detail-carried")
        app.navigationBars["Carried look"].buttons.element(boundBy: 0).tap()
        app.segmentedControls["manager.tab"].buttons["LUTs"].tap()
        XCTAssertTrue(app.staticTexts["Warm Print"].waitForExistence(timeout: 5))
        app.buttons["lut.library.close"].tap()
        openFirstPhotoInformation(app)
        let tile = app.buttons["photo.formula.Carried look"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertTrue(tile.isEnabled)
        tile.tap()
        XCTAssertTrue(app.buttons["photo.look.undo"].waitForExistence(timeout: 10))
    }
}
