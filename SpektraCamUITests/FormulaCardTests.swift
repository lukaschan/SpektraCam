import XCTest

/// A formula as a link, a code and a card: the card's code reads back as the same formula, a
/// copied link pastes back as the formula already in the library, and a saved card or an
/// opened link is previewed before anything is added.
/// Optionally set `SPEKTRACAM_LAYOUT_PHOTO` to a host image and `SPEKTRACAM_LAYOUT_SHOTS` to a
/// host directory for screenshots and the rendered cards.
final class FormulaCardTests: XCTestCase {
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

    @MainActor func testCardCodeAndLink() throws {
        continueAfterFailure = false
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FormulaCard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var photo = ProcessInfo.processInfo.environment["SPEKTRACAM_LAYOUT_PHOTO"]
        if photo == nil {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).image { context in
                UIColor.darkGray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
                UIColor.orange.setFill()
                context.fill(CGRect(x: 40, y: 50, width: 120, height: 90))
            }
            let file = folder.appendingPathComponent("source.png")
            try XCTUnwrap(image.pngData()).write(to: file)
            photo = file.path
        }
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = [
            "--ui-test-library", "--reset-test-library", "--ui-test-import", try XCTUnwrap(photo),
            "--check-formula-card", folder.path,
        ]
        app.launch()

        // Every card's code reads back as its formula, also shrunk and recompressed.
        let reportFile = folder.appendingPathComponent("report.json")
        let done = NSPredicate { _, _ in FileManager.default.fileExists(atPath: reportFile.path) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: done, object: nil)], timeout: 120), .completed)
        let data = try Data(contentsOf: reportFile)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Formula card report"
        attachment.lifetime = .keepAlways
        add(attachment)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(report["result"] as? String, "PASS", report["error"] as? String ?? "")
        let links = try XCTUnwrap(report["links"] as? [String: String])
        if let shots {
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where file.lastPathComponent != "source.png" {
                let copy = URL(fileURLWithPath: shots).appendingPathComponent("card-" + file.lastPathComponent)
                try? FileManager.default.removeItem(at: copy)
                try? FileManager.default.copyItem(at: file, to: copy)
            }
        }

        // The formula's page reads as a procedure and makes the card.
        XCTAssertTrue(app.buttons["library.formulae"].waitForExistence(timeout: 20))
        app.buttons["library.formulae"].tap()
        let row = app.buttons["formula.row.Tungsten night"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let make = app.buttons["formula.card.make"]
        XCTAssertTrue(make.waitForExistence(timeout: 5))
        capture(app, "card-detail")
        make.tap()
        XCTAssertTrue(app.otherElements["formula.card"].waitForExistence(timeout: 10) || app.images["formula.card"].exists)
        let share = app.buttons["formula.card.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 20))
        capture(app, "card-sheet-plain")
        app.buttons["formula.card.photo.0"].tap()
        sleep(1)
        XCTAssertTrue(share.waitForExistence(timeout: 60), "The card with a photo was never ready")
        sleep(1)
        capture(app, "card-sheet-photo")
        app.buttons["formula.card.close"].tap()

        // A copied link pastes back as the formula that is already here.
        let copy = app.buttons["formula.link.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertEqual(copy.label, "Link Copied")
        app.navigationBars["Tungsten night"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["formula.import"].waitForExistence(timeout: 5))
        app.buttons["formula.import"].tap()
        XCTAssertTrue(app.buttons["formula.import.paste"].waitForExistence(timeout: 5))
        capture(app, "card-import-menu")
        app.buttons["formula.import.paste"].tap()
        let allow = app.alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let add = app.buttons["formula.import.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["This formula is already in your library."].exists)
        XCTAssertEqual(add.label, "Done")
        capture(app, "card-paste-link")
        add.tap()

        // A saved card opened in a new library is previewed, then added.
        app.terminate()
        app.launchArguments = [
            "--ui-test-library", "--reset-test-library", "--ui-test-open",
            folder.appendingPathComponent("Contact strip.png").path,
        ]
        app.launch()
        XCTAssertTrue(add.waitForExistence(timeout: 30), "A card's picture was not read")
        XCTAssertTrue(app.staticTexts["F·C200 → F·CA II"].exists || app.staticTexts["Contact strip"].exists)
        XCTAssertEqual(add.label, "Add")
        capture(app, "card-import-picture")
        add.tap()
        XCTAssertTrue(app.buttons["library.formulae"].waitForExistence(timeout: 20))
        app.buttons["library.formulae"].tap()
        XCTAssertTrue(app.buttons["formula.row.Contact strip"].waitForExistence(timeout: 5), "The card's formula was not added")

        // A link opened from outside is previewed the same way; one that is not a formula says so.
        app.terminate()
        app.launchArguments = ["--ui-test-library", "--ui-test-open-link", try XCTUnwrap(links["Tungsten night"])]
        app.launch()
        XCTAssertTrue(add.waitForExistence(timeout: 30), "A formula link was not opened")
        XCTAssertEqual(add.label, "Add")
        capture(app, "card-open-link")
        app.terminate()
        app.launchArguments = ["--ui-test-library", "--ui-test-open-link", "spektracam://f#1.AAAA"]
        app.launch()
        XCTAssertTrue(app.alerts["Couldn’t Open Formula"].waitForExistence(timeout: 30))
    }
}
