import UIKit
import XCTest

final class FormulaRegressionTests: XCTestCase {
    @MainActor func testFirstSavedFormulaDoesNotFollowCurrentEdits() throws {
        continueAfterFailure = false
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160), format: format).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try XCTUnwrap(image.pngData()).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = ["--ui-test-library", "--reset-test-library", "--ui-test-import", source.path]
        app.launch()
        let cell = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        cell.tap()
        app.buttons["photo.develop"].tap()
        let mode = app.buttons["develop.mode.spektrafilm"]
        XCTAssertTrue(mode.waitForExistence(timeout: 20)); mode.tap()
        let info = app.buttons["editor.info"]
        func save(_ name: String) {
            info.tap()
            app.buttons["editor.formula.save"].tap()
            let field = app.textFields["formula.save.name"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap(); field.typeText(name)
            app.buttons["formula.save.confirm"].tap()
            XCTAssertTrue(app.buttons["editor.formula." + name].waitForExistence(timeout: 10))
            info.tap()
        }
        save("Saved C200")
        let otherStock = app.buttons["develop.stock.fujifilm_pro_400h"]
        XCTAssertTrue(otherStock.waitForExistence(timeout: 10)); otherStock.tap()
        XCTAssertTrue(info.label.contains("F·400H"))
        save("Saved 400H")
        info.tap()
        let first = app.buttons["editor.formula.Saved C200"]
        let enabled = NSPredicate(format: "enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: first)], timeout: 20), .completed)
        first.tap()
        XCTAssertTrue(info.label.contains("F·C200"), "First formula followed the source photo's later edits")
        info.tap()
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 15))
        let photoInfo = app.buttons["photo.info"]
        photoInfo.tap()
        app.buttons["photo.formula.Saved 400H"].tap()
        XCTAssertTrue(photoInfo.label.contains("F·400H"))
        app.buttons["photo.formula.Saved C200"].tap()
        XCTAssertTrue(photoInfo.label.contains("F·C200"), "First formula became the photo's current look")
    }

    @MainActor func testFormulaApplicationRenderingAndOriginalExport() throws {
        continueAfterFailure = false
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FormulaChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let files = try [CGSize(width: 257, height: 173), CGSize(width: 163, height: 241)].enumerated().map { index, size in
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                (index == 0 ? UIColor.darkGray : UIColor.lightGray).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor.orange.setFill()
                context.fill(CGRect(x: 10, y: 15, width: size.width / 2, height: size.height / 3))
            }
            let url = folder.appendingPathComponent("source-\(index).png")
            try XCTUnwrap(image.pngData()).write(to: url)
            return url
        }
        let report = folder.appendingPathComponent("report.json")
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = ["--ui-test-library", "--reset-test-library", "--check-formulae", report.path]
        for file in files { app.launchArguments += ["--ui-test-import", file.path] }
        app.launch()
        let done = NSPredicate { _, _ in FileManager.default.fileExists(atPath: report.path) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: done, object: nil)], timeout: 90), .completed)
        let data = try Data(contentsOf: report)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Formula, border and original export regression report"
        attachment.lifetime = .keepAlways
        add(attachment)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(result["result"] as? String, "PASS", result["error"] as? String ?? "")
        let cell = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.tap()
        let develop = app.buttons["photo.develop"]
        XCTAssertTrue(develop.waitForExistence(timeout: 10))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        XCTAssertTrue(develop.isHittable, "Tapping a photo hid its controls")
        let info = app.buttons["photo.info"]
        info.tap()
        let first = app.buttons["photo.formula.First saved"]
        let later = app.buttons["photo.formula.Later saved"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        later.tap()
        let laterName = info.label
        first.tap()
        XCTAssertNotEqual(info.label, laterName, "The first formula just kept the current photo's edits")
        let firstName = info.label
        info.tap()
        develop.tap()
        XCTAssertTrue(app.buttons["develop.mode.spektrafilm"].waitForExistence(timeout: 20))
        app.buttons["editor.info"].tap()
        let editorFirst = app.buttons["editor.formula.First saved"]
        let editorLater = app.buttons["editor.formula.Later saved"]
        XCTAssertTrue(editorFirst.waitForExistence(timeout: 10))
        XCTAssertTrue(editorLater.waitForExistence(timeout: 10))
        editorLater.tap()
        let editorInfo = app.buttons["editor.info"]
        let changedName = editorInfo.label
        let enabled = NSPredicate(format: "enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: editorFirst)], timeout: 20), .completed)
        editorFirst.tap()
        XCTAssertNotEqual(editorInfo.label, changedName, "The editor's first formula kept the current edits")
        XCTAssertTrue(editorInfo.label.contains("F·C200"), "First formula lost its saved stock: " + firstName)
    }

    @MainActor func testFlashPreferenceAndMonochromeSwitches() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = ["--ui-test-library", "--reset-test-library", "--ui-test-camera-demo"]
        app.launch()
        func openSettings() {
            XCTAssertTrue(app.buttons["library.info"].waitForExistence(timeout: 15))
            app.buttons["library.info"].tap()
            let setting = app.switches["about.rememberFlash"]
            for _ in 0..<4 where !setting.isHittable { app.swipeUp() }
            XCTAssertTrue(setting.isHittable)
        }
        openSettings()
        let remember = app.switches["about.rememberFlash"]
        func setRemember(_ enabled: Bool) {
            let value = enabled ? "1" : "0"
            if remember.value as? String != value {
                remember.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            }
            XCTAssertEqual(remember.value as? String, value)
        }
        setRemember(false)
        app.buttons["about.accent.mono"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Monochrome native switch contrast"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Done"].tap()
        app.buttons["camera.open"].tap()
        let flash = app.buttons["camera.flash"]
        XCTAssertTrue(flash.waitForExistence(timeout: 10))
        XCTAssertEqual(flash.value as? String, "Off")
        flash.tap()
        XCTAssertEqual(flash.value as? String, "On")
        app.buttons["camera.close"].tap()
        app.buttons["camera.open"].tap()
        XCTAssertTrue(flash.waitForExistence(timeout: 10))
        XCTAssertEqual(flash.value as? String, "Off")
        app.buttons["camera.close"].tap()
        openSettings()
        setRemember(true)
        app.buttons["Done"].tap()
        app.buttons["camera.open"].tap()
        XCTAssertTrue(flash.waitForExistence(timeout: 10))
        flash.tap()
        app.buttons["camera.close"].tap()
        app.buttons["camera.open"].tap()
        XCTAssertTrue(flash.waitForExistence(timeout: 10))
        XCTAssertEqual(flash.value as? String, "On", "Remember flash did not survive camera dismissal")
        app.buttons["camera.close"].tap()
        openSettings()
        setRemember(false)
        app.buttons["about.accent.magenta"].tap()
        app.buttons["Done"].tap()
    }
}
