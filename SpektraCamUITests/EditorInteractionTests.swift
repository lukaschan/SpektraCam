import XCTest

/// Native gestures catch integration faults that pixel/reference checks cannot observe.
final class EditorInteractionTests: XCTestCase {
    @MainActor func testHorizontalCameraExposureControl() {
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.andreavolpato-spektrafilm")
        app.launchArguments = ["--ui-test-camera-controls"]
        app.launch()
        let slider = app.sliders["camera.exposure"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(slider.frame.width, slider.frame.height * 3)
        let reset = app.buttons["camera.exposureReset"]
        XCTAssertEqual(reset.value as? String, "+0.00 EV")
        drag(slider, to: 0.8)
        XCTAssertGreaterThanOrEqual(reset.frame.height, 44)
        let value = reset.value as? String ?? ""
        XCTAssertTrue(value.hasPrefix("+"))
        XCTAssertNotEqual(value, "+0.00 EV")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Horizontal camera EV control at narrow width"
        capture.lifetime = .keepAlways
        add(capture)
        slider.doubleTap()
        XCTAssertEqual(reset.value as? String, "+0.00 EV")
        drag(slider, to: 0.2)
        XCTAssertTrue((reset.value as? String ?? "").hasPrefix("-"))
        let negative = XCTAttachment(screenshot: app.screenshot())
        negative.name = "Camera EV fills left from zero"
        negative.lifetime = .keepAlways
        add(negative)
        slider.doubleTap()
        XCTAssertEqual(reset.value as? String, "+0.00 EV")
    }
    @MainActor func testFormattingAndMeteringSwitchBounds() {
        let app = openPhoto()
        XCTAssertEqual(app.buttons["develop.mix.value"].value as? String, "100 %")
        app.buttons["editor.tool.adjust"].tap()
        if app.buttons["editor.expand"].value as? String == "Collapsed" { app.buttons["editor.expand"].tap() }
        XCTAssertEqual(app.buttons["tone.pivot.value"].value as? String, "0.35")
        app.descendants(matching: .any).matching(identifier: "adjust.exposureStages").firstMatch.tap()
        let toggle = app.descendants(matching: .any).matching(identifier: "camera.auto_exposure").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(toggle.frame.maxX, app.scrollViews["editor.controls"].frame.maxX - 8)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Exposure metering controls and white selected tab"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["adjust.section.color"].tap()
        if app.buttons["source.warmth.value"].exists {
            XCTAssertEqual(app.buttons["source.warmth.value"].value as? String, "0")
        }
    }

    @MainActor func testNewEditDefaultsInInformation() {
        let app = importPhoto()
        app.buttons["library.select"].tap()
        libraryPhotos(app).firstMatch.tap()
        let selected = XCTAttachment(screenshot: app.screenshot())
        selected.name = "Accent selection with white checkmark"
        selected.lifetime = .keepAlways
        add(selected)
        app.buttons["library.select"].tap()
        func setToggle(_ key: String, to value: String) {
            let toggle = app.switches[key]
            XCTAssertTrue(toggle.exists)
            if toggle.value as? String != value {
                // A native List switch exposes the entire label row as its AX frame.
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            }
            expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: toggle)
            waitForExpectations(timeout: 3)
        }
        func information() {
            app.buttons["library.info"].tap()
            for _ in 0..<5 {
                if app.switches["about.defaultGrain"].isHittable { break }
                app.swipeUp()
            }
        }
        information()
        let keys = ["about.defaultHalation", "about.defaultGrain", "about.defaultMonochromeGrain"]
        let previous = keys.map { app.switches[$0].value as? String ?? "0" }
        for (key, desired) in zip(keys, ["0", "0", "1"]) {
            setToggle(key, to: desired)
        }
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "New edit effect defaults"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["Done"].tap()
        libraryPhotos(app).firstMatch.tap()
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["develop.mode.spektrafilm"].waitForExistence(timeout: 20))
        app.buttons["develop.mode.spektrafilm"].tap()
        app.buttons["editor.tool.effects"].tap()
        for (key, desired) in [("film_render.grain.active", "0"), ("grain.monochrome", "1")] {
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: key).firstMatch.value as? String, desired)
        }
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 20))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["library.info"].waitForExistence(timeout: 10))
        information()
        for (key, value) in zip(keys, previous) {
            setToggle(key, to: value)
        }
        app.buttons["Done"].tap()
    }
    @MainActor func testNeutralEntryAndUniformPhotoActions() {
        let app = openPhoto(activateLook: false, expanded: false)
        let film = app.buttons["develop.mode.spektrafilm"]
        let lut = app.buttons["develop.mode.lut"]
        XCTAssertEqual(app.buttons["editor.expand"].value as? String, "Collapsed")
        XCTAssertFalse(film.isSelected)
        XCTAssertFalse(lut.isSelected)
        XCTAssertTrue(app.buttons["editor.info"].label.contains("Original"))
        let camera = app.buttons["camera.open"]
        for identifier in ["editor.compare", "editor.back"] {
            XCTAssertEqual(app.buttons[identifier].frame.width, camera.frame.width, accuracy: 1, identifier)
            XCTAssertEqual(app.buttons[identifier].frame.height, camera.frame.height, accuracy: 1, identifier)
        }
        // Native toolbar menus report the icon frame, excluding their shared glass surface.
        XCTAssertTrue((36...44).contains(app.buttons["editor.history"].frame.width))
        let neutral = XCTAttachment(screenshot: app.screenshot())
        neutral.name = "Neutral collapsed editor with uniform actions"
        neutral.lifetime = .keepAlways
        add(neutral)
        film.tap()
        XCTAssertTrue(film.isSelected)
        app.buttons["editor.history"].tap()
        app.buttons["Undo"].tap()
        XCTAssertFalse(film.isSelected)
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["photo.revert"].isEnabled, "Opening an editor must not save a default look")
        for identifier in ["photo.export", "photo.revert", "photo.delete"] {
            XCTAssertEqual(app.buttons[identifier].frame.width, app.buttons["camera.open"].frame.width, accuracy: 1)
            XCTAssertEqual(app.buttons[identifier].frame.height, app.buttons["camera.open"].frame.height, accuracy: 1)
        }
        let viewer = XCTAttachment(screenshot: app.screenshot())
        viewer.name = "Uniform photo page actions"
        viewer.lifetime = .keepAlways
        add(viewer)
    }

    @MainActor func testFilesImportFromInformation() {
        let app = importPhoto()
        let camera = app.buttons["camera.open"]
        let delete = app.buttons["library.delete"]
        XCTAssertLessThan(camera.frame.maxY, delete.frame.minY)
        XCTAssertEqual(camera.frame.midX, delete.frame.midX, accuracy: 2)
        XCTAssertGreaterThan(camera.frame.width, delete.frame.width)
        app.buttons["library.info"].tap()
        let files = app.buttons["about.importFiles"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Files import from library settings"
        capture.lifetime = .keepAlways
        add(capture)
    }

    /// Run on the isolated simulator with enough synthetic Photos fixtures to scroll.
    @MainActor func testPickerReturnsToRecentAndRetainsImportedChecks() {
        let app = importPhoto()
        app.buttons["library.import"].tap()
        let cells = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 10))
        func visibleCells() -> [XCUIElement] {
            let area = CGRect(x: 0, y: 150, width: app.frame.width, height: app.frame.height - 270)
            return cells.allElementsBoundByIndex.filter {
                let frame = $0.frame
                return frame.width > 50 && area.contains(CGPoint(x: frame.midX, y: frame.midY))
            }.sorted { a, b in a.frame.minY == b.frame.minY ? a.frame.minX < b.frame.minX : a.frame.minY < b.frame.minY }
        }
        let recent = visibleCells().first!
        let recentLabel = recent.label
        for _ in 0..<6 { app.swipeUp() }
        let old = visibleCells().last!
        let oldLabel = old.label
        XCTAssertNotEqual(recentLabel, oldLabel)
        old.tap()
        app.navigationBars["Photos"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label == %@", "2 photos"), evaluatedWith: app.staticTexts["library.count"])
        waitForExpectations(timeout: 20)
        app.buttons["library.import"].tap()
        let returnedRecent = cells.matching(NSPredicate(format: "label == %@", recentLabel)).firstMatch
        XCTAssertTrue(returnedRecent.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(returnedRecent.isHittable, "Picker reopened at the older selected photo")
        let initial = XCTAttachment(screenshot: app.screenshot())
        initial.name = "Picker reopens at recent photos"
        initial.lifetime = .keepAlways
        add(initial)
        for _ in 0..<6 { app.swipeUp() }
        let checked = cells.matching(NSPredicate(format: "label == %@", oldLabel)).firstMatch
        XCTAssertTrue(checked.waitForExistence(timeout: 5))
        print("IMPORTED PICKER ITEM", checked.debugDescription)
        XCTAssertTrue(checked.isSelected, "Previously imported photo lost its checked marker")
        let selection = XCTAttachment(screenshot: app.screenshot())
        selection.name = "Older imported photo remains checked"
        selection.lifetime = .keepAlways
        add(selection)
    }

    @MainActor func testCameraLibraryReturnsToLatestAfterScrolling() {
        let app = importPhoto()
        app.buttons["library.import"].tap()
        let cells = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 10))
        var added = 0
        for _ in 0..<5 {
            let area = CGRect(x: 0, y: 150, width: app.frame.width, height: app.frame.height - 270)
            let visible = cells.allElementsBoundByIndex.filter {
                let frame = $0.frame
                return frame.width > 50 && area.contains(CGPoint(x: frame.midX, y: frame.midY))
            }
            for cell in visible where !cell.isSelected {
                cell.tap()
                added += 1
                if added == 18 { break }
            }
            if added == 18 { break }
            app.swipeUp()
        }
        XCTAssertEqual(added, 18, "Seed the isolated simulator with the synthetic picker fixtures")
        app.navigationBars["Photos"].buttons["Done"].tap()
        // Duplicate imports are intentionally skipped; this test needs a scrollable library.
        expectation(for: NSPredicate(block: { _, _ in
            Int(app.staticTexts["library.count"].label.split(separator: " ").first ?? "0") ?? 0 >= 15
        }), evaluatedWith: app)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["library.import"])
        waitForExpectations(timeout: 30)
        let latestID = libraryPhotos(app).firstMatch.identifier
        let initialY = app.buttons[latestID].frame.minY
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertTrue(!app.buttons[latestID].exists || app.buttons[latestID].frame.minY < initialY - 10)
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.library"].waitForExistence(timeout: 10))
        app.buttons["camera.library"].tap()
        let latest = app.buttons[latestID]
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(latest.frame.minY, 100)
        XCTAssertEqual(latest.frame.minY, initialY, accuracy: 1)
        XCTAssertLessThan(latest.frame.maxY, app.frame.height / 2)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Camera returns to top of newest-first library"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor func testPreviewSettingsAndBatchExport() {
        let app = importPhoto(count: 2)
        app.buttons["library.info"].tap()
        let library = app.buttons["about.libraryPreview"]
        let editor = app.buttons["about.editorPreview"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        XCTAssertTrue(editor.exists)
        library.tap()
        app.buttons["720 px"].tap()
        editor.tap()
        app.buttons["2,160 px"].tap()
        let settings = XCTAttachment(screenshot: app.screenshot())
        settings.name = "Independent library and editor preview settings"
        settings.lifetime = .keepAlways
        add(settings)
        app.buttons["Done"].tap()
        app.buttons["library.select"].tap()
        XCTAssertFalse(app.buttons["library.export"].isEnabled)
        libraryPhotos(app).element(boundBy: 0).tap()
        libraryPhotos(app).element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["library.export"].isEnabled)
        XCTAssertLessThan(app.buttons["library.export"].frame.midX, app.buttons["library.revert"].frame.midX)
        app.buttons["library.export"].tap()
        XCTAssertTrue(app.buttons["batch.prepareShare"].waitForExistence(timeout: 10))
        app.buttons["S"].tap()
        app.buttons["batch.prepareShare"].tap()
        let ready = app.buttons["batch.share"]
        XCTAssertTrue(ready.waitForExistence(timeout: 45))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: ready)
        waitForExpectations(timeout: 45)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Ready to share").count, 2)
        let batch = XCTAttachment(screenshot: app.screenshot())
        batch.name = "Sequential batch export ready to share"
        batch.lifetime = .keepAlways
        add(batch)
        app.buttons["Done"].tap()
        // Restore defaults for other tests; these preferences are separate from the test library.
        app.buttons["library.select"].tap()
        app.buttons["library.info"].tap()
        app.buttons["about.libraryPreview"].tap(); app.buttons["1,080 px"].tap()
        app.buttons["about.editorPreview"].tap(); app.buttons["1,080 px"].tap()
    }
    @MainActor func testStraightenDragAndPanelReentry() {
        let app = openPhoto()
        XCTAssertEqual(app.buttons["editor.expand"].value as? String, "Expanded")
        app.buttons["editor.tool.crop"].tap()
        let slider = app.sliders["crop.straighten"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        drag(slider, to: 0.65)
        XCTAssertFalse((slider.value as? String ?? "").hasPrefix("-45"))
        drag(slider, to: 0.35)
        let left = slider.value as? String
        drag(slider, to: 0.6)
        XCTAssertNotEqual(slider.value as? String, left)
        app.buttons["editor.tool.develop"].tap()
        XCTAssertEqual(app.buttons["editor.expand"].value as? String, "Collapsed")
    }
    @MainActor func testChineseLocalizationPanels() {
        let app = importPhoto()
        app.terminate()
        app.launchArguments = [
            "--ui-test-library", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["图库"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["library.count"].label, "1 张照片")
        app.buttons["library.info"].tap()
        XCTAssertTrue(app.buttons["about.language"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["about.language"].label.contains("简体中文"))
        XCTAssertTrue(app.staticTexts["语言"].exists)
        let about = XCTAttachment(screenshot: app.screenshot())
        about.name = "Chinese About and language"
        about.lifetime = .keepAlways
        add(about)
        app.buttons["完成"].tap()
        libraryPhotos(app).firstMatch.tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["photo.develop"].label, "冲洗")
        let photo = app.images["照片"]
        XCTAssertTrue(photo.waitForExistence(timeout: 15))
        XCTAssertEqual(photo.value as? String, "缩放 100%")
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.tool.develop"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["印相"].exists)
        let develop = XCTAttachment(screenshot: app.screenshot())
        develop.name = "Chinese Develop"
        develop.lifetime = .keepAlways
        add(develop)
        app.buttons["editor.tool.adjust"].tap()
        XCTAssertTrue(app.buttons["高光/阴影"].waitForExistence(timeout: 5))
        app.buttons["高光/阴影"].tap()
        XCTAssertTrue(app.sliders["tone.highlights"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["高光"].exists)
        XCTAssertEqual(app.buttons["adjust.liftGainRange"].label, "切换高光和阴影范围")
        XCTAssertEqual(app.buttons["adjust.liftGainRange"].value as? String, "±2")
        app.buttons["editor.tool.crop"].tap()
        let area = app.otherElements["crop.area"]
        XCTAssertTrue(area.waitForExistence(timeout: 5))
        XCTAssertTrue((area.value as? String ?? "").contains("100%"))
        XCTAssertFalse((area.value as? String ?? "").contains("百分之"))
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.buttons["export.save"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.buttons["export.save"].label.contains("照片"))
        XCTAssertEqual(app.buttons["export.share"].label, "共享")
        let exported = XCTAttachment(screenshot: app.screenshot())
        exported.name = "Chinese Export"
        exported.lifetime = .keepAlways
        add(exported)
    }

    @MainActor func testNativeLanguageSettingsPage() {
        let app = openPhoto()
        app.buttons["editor.tool.adjust"].tap()
        drag(app.sliders["tone.exposure"], to: 0.6)
        let savedExposure = app.buttons["tone.exposure.value"].value as? String
        app.buttons["editor.back"].tap()
        app.terminate()
        app.launchArguments = ["--ui-test-library"]
        app.launch()
        app.buttons["library.info"].tap()
        app.buttons["about.language"].tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        print("NATIVE APP SETTINGS", settings.debugDescription)
        let capture = XCTAttachment(screenshot: settings.screenshot())
        capture.name = "Native app language settings"
        capture.lifetime = .keepAlways
        add(capture)
        if !settings.staticTexts["Language"].waitForExistence(timeout: 3) {
            for _ in 0..<8 {
                let apps = settings.buttons["Apps"]
                if apps.exists && apps.isHittable {
                    apps.tap()
                    break
                }
                let cell = settings.cells.containing(.staticText, identifier: "Apps").firstMatch
                if cell.exists && cell.isHittable {
                    cell.tap()
                    break
                }
                settings.swipeUp()
            }
            print("SETTINGS APPS", settings.debugDescription)
            let spektra = settings.staticTexts["SpektraCam"]
            if !spektra.waitForExistence(timeout: 2) {
                let search = settings.searchFields.firstMatch
                if search.exists {
                    search.tap()
                    search.typeText("SpektraCam")
                }
            }
            if spektra.waitForExistence(timeout: 5) { spektra.tap() }
        }
        print("SETTINGS APP PAGE", settings.debugDescription)
        let page = XCTAttachment(screenshot: settings.screenshot())
        page.name = "SpektraCam Settings page"
        page.lifetime = .keepAlways
        add(page)
        let language = settings.staticTexts["Language"]
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        language.tap()
        XCTAssertTrue(settings.staticTexts["English"].waitForExistence(timeout: 5))
        XCTAssertTrue(settings.staticTexts["简体中文"].exists)
        let choices = XCTAttachment(screenshot: settings.screenshot())
        choices.name = "Native English and Chinese choices"
        choices.lifetime = .keepAlways
        add(choices)
        settings.staticTexts["简体中文"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["图库"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["library.count"].label, "1 张照片")
        let switched = XCTAttachment(screenshot: app.screenshot())
        switched.name = "Chinese selected in native Settings"
        switched.lifetime = .keepAlways
        add(switched)
        settings.activate()
        if !settings.staticTexts["English"].exists {
            settings.staticTexts["Language"].tap()
        }
        XCTAssertTrue(settings.staticTexts["English"].waitForExistence(timeout: 5))
        settings.staticTexts["English"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["library.count"].label, "1 photo")
        libraryPhotos(app).firstMatch.tap()
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.tool.adjust"].waitForExistence(timeout: 30))
        app.buttons["editor.tool.adjust"].tap()
        XCTAssertEqual(app.buttons["tone.exposure.value"].value as? String, savedExposure)
    }

    @MainActor func testChineseLargeTextEffectSwitchFits() {
        let app = importPhoto()
        app.terminate()
        app.launchArguments = [
            "--ui-test-library", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(libraryPhotos(app).firstMatch.waitForExistence(timeout: 10))
        libraryPhotos(app).firstMatch.tap()
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.tool.effects"].waitForExistence(timeout: 30))
        app.buttons["editor.tool.effects"].tap()
        let toggle = app.descendants(matching: .any).matching(
            identifier: "film_render.grain.active"
        ).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(toggle.frame.maxX, app.frame.maxX - 8)
        XCTAssertGreaterThanOrEqual(toggle.frame.minX, app.frame.minX + 8)
        XCTAssertTrue(app.staticTexts["颗粒"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Chinese large-text effects"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor func testAboutLinks() {
        let app = importPhoto()
        XCTAssertEqual(app.staticTexts["library.count"].label, "1 photo")
        app.buttons["library.info"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["Runze · Website"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Andrea Volpato · Spektrafilm"].exists)
        XCTAssertTrue(
            app.staticTexts["All editing features are free."].exists
                || app.staticTexts["Free and open source. All editing features are free."].exists)
    }
    @MainActor func testPhotoRevertAndControls() {
        let app = openPhoto()
        app.buttons["editor.tool.adjust"].tap()
        drag(app.sliders["tone.exposure"], to: 0.6)
        app.buttons["editor.back"].tap()
        let revert = app.buttons["photo.revert"]
        XCTAssertTrue(revert.waitForExistence(timeout: 10))
        XCTAssertTrue(revert.isEnabled)
        XCTAssertEqual(
            app.buttons["photo.export"].frame.height, app.buttons["photo.delete"].frame.height,
            accuracy: 2)
        XCTAssertLessThan(revert.frame.maxX, app.buttons["photo.delete"].frame.minX)
        revert.tap()
        app.buttons["Revert to Original"].tap()
        expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: revert)
        waitForExpectations(timeout: 10)
    }
    @MainActor func testStraightenedCropCanReframe() {
        let app = openPhoto()
        app.buttons["editor.tool.crop"].tap()
        let slider = app.sliders["crop.straighten"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        drag(slider, to: 0.65)
        let area = app.otherElements["crop.area"]
        XCTAssertTrue(area.waitForExistence(timeout: 5))
        let before = area.value as? String
        area.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: area.coordinate(withNormalizedOffset: CGVector(dx: 0.56, dy: 0.53)))
        XCTAssertNotEqual(area.value as? String, before)
        let framing = (area.value as? String ?? "").components(separatedBy: "framing ").last!.split(
            separator: ",")
        if framing.count == 2, let x = Double(framing[0].trimmingCharacters(in: .whitespaces)),
            let y = Double(framing[1].trimmingCharacters(in: .whitespaces))
        {
            XCTAssertGreaterThan(
                x * 0.06 * area.frame.width * area.frame.width + y * 0.03 * area.frame.height
                    * area.frame.height, 0,
                "Photo moved against the drag direction")
        } else {
            XCTFail("Missing framing accessibility value")
        }
    }
    @MainActor func testLargeTextEffectSwitchFits() {
        let app = importPhoto()
        app.terminate()
        app.launchArguments = [
            "--ui-test-library", "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        let photo = libraryPhotos(app).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.tool.effects"].waitForExistence(timeout: 30))
        app.buttons["editor.tool.effects"].tap()
        let toggle = app.descendants(matching: .any).matching(
            identifier: "film_render.grain.active"
        ).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(toggle.frame.maxX, app.frame.maxX - 8)
        XCTAssertGreaterThanOrEqual(toggle.frame.minX, app.frame.minX + 8)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Large-text adaptive effect switch"
        capture.lifetime = .keepAlways
        add(capture)
    }
    @MainActor func testPhotoPinchThenPage() {
        let app = importPhoto(count: 2)
        let secondID = libraryPhotos(app).element(boundBy: 1).identifier.replacingOccurrences(
            of: "library.photo.", with: "")
        libraryPhotos(app).element(boundBy: 0).tap()
        let image = app.images["Photo"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        image.pinch(withScale: 2, velocity: 1)
        expectation(
            for: NSPredicate(format: "value != %@", "100 percent zoom"), evaluatedWith: image)
        waitForExpectations(timeout: 5)
        // Once zoomed, XCTest generates a full-window pinch that starts on the floating
        // controls. Use the native double-tap fit gesture before checking paging handoff.
        image.doubleTap()
        expectation(
            for: NSPredicate(format: "value == %@", "100 percent zoom"), evaluatedWith: image)
        waitForExpectations(timeout: 5)
        // The grid opens at the newest item; the viewer's chronological previous page is to the right.
        image.swipeRight()
        expectation(
            for: NSPredicate(format: "isSelected == true"),
            evaluatedWith: app.buttons["photo.filmstrip." + secondID])
        waitForExpectations(timeout: 5)
    }
    @MainActor func testCancelledPhotoSwipeSettles() {
        let app = importPhoto(count: 2)
        let id = libraryPhotos(app).element(boundBy: 0).identifier.replacingOccurrences(
            of: "library.photo.", with: "")
        libraryPhotos(app).element(boundBy: 0).tap()
        let image = app.images["Photo"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
                forDuration: 0.1,
                thenDragTo: image.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)),
                withVelocity: .slow, thenHoldForDuration: 0.4)
            XCTAssertTrue(app.buttons["photo.filmstrip." + id].isSelected)
            XCTAssertEqual(
                image.frame.midX, app.frame.midX, accuracy: 2, "Cancelled swipe left a partial page"
            )
        }
        image.swipeLeft()
        image.swipeRight()
        XCTAssertTrue(app.buttons["photo.filmstrip." + id].isSelected)
        XCTAssertEqual(image.frame.midX, app.frame.midX, accuracy: 2)
    }
    @MainActor func testLUTManagerPresentation() throws {
        let app = importPhoto()
        let manager = app.buttons["library.luts"]
        XCTAssertTrue(manager.waitForExistence(timeout: 5))
        XCTAssertLessThan(app.staticTexts["library.count"].frame.maxY, manager.frame.minY)
        manager.tap()
        XCTAssertTrue(app.buttons["lut.import"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["lut.delete"].isEnabled)
        XCTAssertFalse(
            app.buttons["lut.none"].exists, "Manager must not edit a photo's LUT assignment")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Shared LUT Manager"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["lut.library.close"].tap()
        XCTAssertTrue(manager.waitForExistence(timeout: 5))
    }
    @MainActor func testCameraPresentationKeepsEditor() throws {
        let app = importPhoto()
        app.buttons["camera.open"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["camera.unavailable"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["camera.shutter"].isEnabled)
        XCTAssertEqual(
            app.buttons["camera.shutter"].frame.midX, app.frame.midX, accuracy: 1,
            "The camera shutter is not centered")
        app.buttons["camera.library"].tap()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["camera.close"].exists)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'"))
            .firstMatch.tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.close"].waitForExistence(timeout: 5))
        app.buttons["camera.close"].tap()
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.back"].waitForExistence(timeout: 30))
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.close"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Simulator camera unavailable"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["camera.close"].tap()
        XCTAssertTrue(app.buttons["editor.back"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["editor.expand"].value as? String, "Expanded")
    }
    @MainActor func testCameraLibraryReturnsToRoot() {
        let app = openPhoto()
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.library"].waitForExistence(timeout: 10))
        app.buttons["camera.library"].tap()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        XCTAssertEqual(libraryPhotos(app).firstMatch.value as? String, "Edited")
        XCTAssertFalse(app.buttons["editor.back"].exists)
        XCTAssertFalse(app.buttons["photo.develop"].exists)
        XCTAssertFalse(app.buttons["camera.close"].exists)
    }
    @MainActor func testRevertSelectedPhoto() throws {
        let app = openPhoto()
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 30))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["library.select"].waitForExistence(timeout: 5))
        app.buttons["library.select"].tap()
        XCTAssertTrue(app.buttons["library.revert"].waitForExistence(timeout: 5))
        expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: app.buttons["library.import"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["library.revert"].isEnabled)
        libraryPhotos(app).firstMatch.tap()
        XCTAssertTrue(app.buttons["library.revert"].isEnabled)
        app.buttons["library.revert"].tap()
        XCTAssertTrue(app.buttons["Revert to Original"].waitForExistence(timeout: 5))
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["photo.badge.edited"].exists)
        app.buttons["library.revert"].tap()
        app.buttons["Revert to Original"].tap()
        let original = NSPredicate(format: "value == %@", "Original")
        expectation(for: original, evaluatedWith: libraryPhotos(app).firstMatch)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.descendants(matching: .any)["photo.badge.edited"].exists)
        app.buttons["library.select"].tap()
        XCTAssertTrue(app.buttons["library.import"].exists)
    }
    @MainActor func testNativeZoomAndGuardedExit() throws {
        let app = openPhoto()
        app.buttons["editor.tool.develop"].tap()
        let photo = app.images["Edited photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        let fit = NSPredicate(format: "value == %@", "100 percent zoom")
        expectation(for: fit, evaluatedWith: photo)
        waitForExpectations(timeout: 15)
        photo.doubleTap()
        let zoomed = NSPredicate(format: "value != %@", "100 percent zoom")
        expectation(for: zoomed, evaluatedWith: photo)
        waitForExpectations(timeout: 10)
        let compareZoom = photo.value as? String
        app.buttons["editor.compare"].tap()
        XCTAssertEqual(photo.value as? String, compareZoom, "Compare reset the zoom")
        app.buttons["editor.compare"].tap()
        XCTAssertEqual(photo.value as? String, compareZoom, "Returning to edits reset the zoom")
        let zoomImage = XCTAttachment(screenshot: app.screenshot())
        zoomImage.name = "Native double tap zoom"
        zoomImage.lifetime = .keepAlways
        add(zoomImage)
        let doubleTapValue = photo.value as? String
        photo.pinch(withScale: 1.2, velocity: 1)
        XCTAssertNotEqual(
            photo.value as? String, doubleTapValue, "Native pinch did not change zoom")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)))
        photo.doubleTap()
        expectation(for: fit, evaluatedWith: photo)
        waitForExpectations(timeout: 10)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.4))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.4)))
        XCTAssertTrue(
            app.buttons["editor.back"].exists, "Editing allowed an accidental navigation pop")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Native zoom and guarded exit"
        image.lifetime = .keepAlways
        add(image)
        let portraitPhoto = photo.frame
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertGreaterThan(
            app.frame.height, app.frame.width, "The iPhone interface rotated out of portrait")
        XCTAssertEqual(photo.frame.height, portraitPhoto.height, accuracy: 1)
        XCTAssertEqual(photo.frame.width, portraitPhoto.width, accuracy: 1)
        let locked = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        locked.name = "iPhone portrait orientation lock"
        locked.lifetime = .keepAlways
        add(locked)
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.sheets["Return to Photo?"].exists)
        XCTAssertFalse(app.buttons["editor.back"].exists)
    }
    @MainActor func testCompareKeepsCroppedZoom() {
        let app = openPhoto()
        app.buttons["editor.tool.crop"].tap()
        app.buttons["crop.ratio.square"].tap()
        app.buttons["editor.tool.adjust"].tap()
        app.buttons["editor.tool.adjust"].tap()
        let photo = app.images["Edited photo"]
        let square = NSPredicate { _, _ in abs(photo.frame.width - photo.frame.height) < 2 }
        expectation(for: square, evaluatedWith: photo)
        waitForExpectations(timeout: 15)
        photo.doubleTap()
        let zoomed = NSPredicate(format: "value != %@", "100 percent zoom")
        expectation(for: zoomed, evaluatedWith: photo)
        waitForExpectations(timeout: 10)
        let value = photo.value as? String
        XCTAssertLessThan(
            photo.frame.minY, app.buttons["editor.info"].frame.maxY,
            "Zoomed photo cannot extend behind the information panel")
        app.buttons["editor.compare"].tap()
        XCTAssertEqual(photo.value as? String, value, "Comparing an uncropped original reset zoom")
        app.buttons["editor.compare"].tap()
        XCTAssertEqual(photo.value as? String, value, "Returning to a crop reset zoom")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Cropped comparison preserves zoom behind glass"
        capture.lifetime = .keepAlways
        add(capture)
    }
    @MainActor private func importPhoto(count: Int = 1) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.andreavolpato-spektrafilm")
        app.launchArguments = ["--ui-test-library", "--reset-test-library"]
        app.launch()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["library.delete"].isEnabled)
        app.buttons["library.import"].tap()
        if app.buttons["From Photos"].exists { app.buttons["From Photos"].tap() }
        // Prefer native picker elements. Some Simulator runs expose only its remote surface.
        let cells = app.images.matching(identifier: "PXGGridLayout-Info")
        if cells.firstMatch.waitForExistence(timeout: 5) {
            cells.element(boundBy: 0).tap()
            if count > 1 { cells.element(boundBy: 1).tap() }
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.167, dy: 0.24)).press(
                forDuration: 0.15)
            if count > 1 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24)).press(
                    forDuration: 0.15)
            }
        }
        let picked = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picked.name = "System picker selection"
        picked.lifetime = .keepAlways
        self.add(picked)
        let done = app.navigationBars["Photos"].buttons["Done"]
        if done.exists {
            XCTAssertTrue(done.isEnabled)
            done.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.115)).press(
                forDuration: 0.15)
        }
        let photo = libraryPhotos(app).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 30), app.debugDescription)
        return app
    }
    /// A physical thumb drag also checks the new native glass track, independent of AX value formatting.
    @MainActor private func drag(_ slider: XCUIElement, to position: CGFloat) {
        let current: CGFloat
        if let number = slider.value as? NSNumber {
            current = CGFloat(number.doubleValue)
        } else {
            let text = slider.value as? String ?? "50%"
            if text.contains("degrees"),
                let degrees = Double(text.replacingOccurrences(of: " degrees", with: ""))
            {
                current = CGFloat((degrees + 45) / 90)
            } else {
                let number =
                    Double(text.replacingOccurrences(of: "%", with: ""))
                    ?? (text.contains("%") ? 50 : 0.5)
                current = CGFloat(text.contains("%") ? number / 100 : number)
            }
        }
        slider.coordinate(withNormalizedOffset: CGVector(dx: current, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5)),
            withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    @MainActor private func libraryPhotos(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'"))
    }
    @MainActor private func openPhoto(activateLook: Bool = true, expanded: Bool = true) -> XCUIApplication {
        let app = importPhoto()
        libraryPhotos(app).firstMatch.tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.histogram"].waitForExistence(timeout: 30))
        if activateLook { app.buttons["develop.mode.spektrafilm"].tap() }
        if expanded && app.buttons["editor.expand"].value as? String == "Collapsed" {
            app.buttons["editor.expand"].tap()
        }
        return app
    }

    @MainActor func testLibraryRestartEditAndDelete() {
        let app = openPhoto()
        app.buttons["editor.tool.adjust"].tap()
        let slider = app.sliders["tone.exposure"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        drag(slider, to: 0.75)
        let savedValue = app.buttons["tone.exposure.value"].value as? String
        XCTAssertNotEqual(savedValue, "0.00 EV")
        // A recipe also survives termination without using the editor's Save action.
        Thread.sleep(forTimeInterval: 0.5)
        app.terminate()
        app.launchArguments = ["--ui-test-library"]
        app.launch()
        XCTAssertTrue(libraryPhotos(app).firstMatch.waitForExistence(timeout: 15))
        libraryPhotos(app).firstMatch.tap()
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.tool.adjust"].waitForExistence(timeout: 30))
        app.buttons["editor.tool.adjust"].tap()
        XCTAssertEqual(app.buttons["tone.exposure.value"].value as? String, savedValue)
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.delete"].waitForExistence(timeout: 30))
        app.buttons["photo.delete"].tap()
        app.buttons["Delete App Copy"].tap()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        XCTAssertEqual(libraryPhotos(app).count, 0)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Your Library"].waitForExistence(timeout: 10))
        XCTAssertEqual(libraryPhotos(app).count, 0)
    }

    @MainActor func testLibraryFiltersSelectionAndOriginalExport() {
        let app = importPhoto()
        app.buttons["library.filter"].tap()
        app.buttons["RAW"].tap()
        // The seeded first asset is a rendered photo.
        XCTAssertTrue(app.staticTexts["No RAW Photos"].waitForExistence(timeout: 5))
        app.buttons["library.filter"].tap()
        app.buttons["All"].tap()
        XCTAssertTrue(libraryPhotos(app).firstMatch.waitForExistence(timeout: 5))
        app.buttons["library.select"].tap()
        XCTAssertFalse(app.buttons["library.delete"].isEnabled)
        libraryPhotos(app).firstMatch.tap()
        XCTAssertTrue(app.buttons["library.delete"].isEnabled)
        XCTAssertTrue(app.buttons["Cancel Selection"].exists)
        app.buttons["library.select"].tap()
        XCTAssertFalse(app.buttons["library.delete"].isEnabled)
        libraryPhotos(app).firstMatch.tap()
        app.buttons["photo.export"].tap()
        XCTAssertTrue(app.buttons["S"].waitForExistence(timeout: 10))
        app.buttons["S"].tap()
        XCTAssertTrue(app.buttons["export.save"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["export.save"].isHittable)
        XCTAssertTrue(app.buttons["export.share"].isHittable)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 5))
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "Photo view before development"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor func testFilmstripAndEditedBadge() {
        let app = importPhoto(count: 2)
        XCTAssertEqual(app.staticTexts["library.count"].label, "2 photos")
        XCTAssertEqual(libraryPhotos(app).count, 2)
        let firstID = libraryPhotos(app).element(boundBy: 0).identifier.replacingOccurrences(
            of: "library.photo.", with: "")
        let secondID = libraryPhotos(app).element(boundBy: 1).identifier.replacingOccurrences(
            of: "library.photo.", with: "")
        libraryPhotos(app).element(boundBy: 0).tap()
        let first = app.buttons["photo.filmstrip." + firstID]
        let second = app.buttons["photo.filmstrip." + secondID]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isSelected)
        app.images["Photo"].swipeLeft()
        let selected = NSPredicate(format: "isSelected == true")
        expectation(for: selected, evaluatedWith: second)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(second.isSelected)
        XCTAssertFalse(first.isSelected)
        for _ in 0..<5 {
            app.images["Photo"].swipeRight()
            expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: first)
            waitForExpectations(timeout: 5)
            app.images["Photo"].swipeLeft()
            expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: second)
            waitForExpectations(timeout: 5)
        }
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.back"].waitForExistence(timeout: 30))
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 30))
        XCTAssertEqual(second.value as? String, "Edited")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(libraryPhotos(app).firstMatch.waitForExistence(timeout: 10))
        let edited = app.buttons["library.photo." + secondID]
        XCTAssertEqual(edited.value as? String, "Edited")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Edited badge in gallery"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func testPhotoInformationAndCanvasBounds() {
        let app = openPhoto()
        let info = app.buttons["editor.info"]
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        let image = app.images["Edited photo"]
        XCTAssertTrue(image.waitForExistence(timeout: 20))
        XCTAssertEqual(info.value as? String, "Collapsed")
        let toolbar =
            ["crop", "develop", "adjust", "effects"].map { app.buttons["editor.tool." + $0] }
            + [app.buttons["editor.export"]]
        for button in toolbar {
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, "Tool touch area is too narrow")
            XCTAssertEqual(button.frame.minY, toolbar[0].frame.minY, accuracy: 1)
        }
        // Native toolbar segments expose their 36 pt visual frame inside a 48 pt glass surface.
        // Check the required 44 pt touch height with physical taps outside that visual frame.
        for name in ["crop", "develop", "adjust", "effects"] {
            let button = app.buttons["editor.tool." + name]
            let center = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.withOffset(CGVector(dx: 0, dy: -21)).tap()
            XCTAssertTrue(button.isSelected, "The native tool did not accept its upper touch edge")
            center.withOffset(CGVector(dx: 0, dy: 21)).tap()
            XCTAssertFalse(button.isSelected, "The native tool did not accept its lower touch edge")
        }
        app.buttons["editor.tool.develop"].tap()
        let before = image.frame
        XCTAssertGreaterThanOrEqual(before.minY, info.frame.maxY + 6)
        XCTAssertLessThanOrEqual(before.maxY, app.buttons["editor.tool.develop"].frame.minY + 1)
        app.buttons["editor.histogram"].tap()
        XCTAssertEqual(info.value as? String, "Collapsed", "Histogram opened photo details")
        info.tap()
        XCTAssertEqual(info.value as? String, "Expanded")
        XCTAssertEqual(image.frame.minY, before.minY, accuracy: 1)
        XCTAssertEqual(image.frame.height, before.height, accuracy: 1)
        for row in ["location", "time", "camera", "lens", "exposure", "format", "colorSpace"] {
            XCTAssertTrue(
                app.descendants(matching: .any).matching(identifier: "editor." + row).firstMatch
                    .exists, "Missing metadata row: " + row)
        }
        let editorColor = app.descendants(matching: .any).matching(identifier: "editor.colorSpace")
            .firstMatch
        XCTAssertTrue(editorColor.exists)
        XCTAssertLessThanOrEqual(
            editorColor.frame.maxY, app.scrollViews["editor.details"].frame.maxY)
        let metadataCapture = XCTAttachment(screenshot: app.screenshot())
        metadataCapture.name = "All seven photo detail rows"
        metadataCapture.lifetime = .keepAlways
        add(metadataCapture)
        app.buttons["editor.histogram"].tap()
        XCTAssertEqual(info.value as? String, "Expanded", "Histogram closed photo details")
        info.tap()
        XCTAssertEqual(info.value as? String, "Collapsed")
        app.buttons["editor.tool.crop"].tap()
        XCTAssertFalse(app.buttons["editor.info"].exists)
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.info"].waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "photo.banner.date").firstMatch
                .exists)
        let badge = app.images["photo.badge.edited"]
        XCTAssertTrue(badge.exists)
        XCTAssertLessThan(badge.frame.maxY, app.buttons["photo.info"].frame.minY)
        let viewerInfo = app.buttons["photo.info"]
        app.buttons["photo.histogram"].tap()
        XCTAssertEqual(viewerInfo.value as? String, "Collapsed")
        viewerInfo.tap()
        XCTAssertEqual(viewerInfo.value as? String, "Expanded")
        let photoColor = app.descendants(matching: .any).matching(identifier: "photo.colorSpace")
            .firstMatch
        XCTAssertTrue(photoColor.exists)
        XCTAssertLessThanOrEqual(photoColor.frame.maxY, app.scrollViews["photo.details"].frame.maxY)
    }

    @MainActor func testCollapsedAdjustmentsAndCouplerBounds() {
        let app = openPhoto()
        app.buttons["editor.tool.adjust"].tap()
        if app.buttons["editor.expand"].value as? String == "Expanded" {
            app.buttons["editor.expand"].tap()
        }
        let controls = app.scrollViews["editor.controls"]
        func assertVisible(_ identifiers: [String]) {
            for identifier in identifiers {
                let slider = app.sliders[identifier]
                XCTAssertTrue(slider.waitForExistence(timeout: 5))
                XCTAssertGreaterThanOrEqual(slider.frame.minY, controls.frame.minY)
                XCTAssertLessThanOrEqual(slider.frame.maxY, controls.frame.maxY)
                XCTAssertTrue(slider.isHittable, identifier)
            }
        }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.buttons["adjust.section.liftGain"].tap()
        assertVisible(["tone.highlights", "tone.shadows"])
        capture("Collapsed Lift and Gain")
        app.buttons["adjust.section.color"].tap()
        assertVisible(["source.warmth", "source.tint", "source.saturation"])
        capture("Collapsed Color")

        app.buttons["editor.expand"].tap()
        app.buttons["Dye couplers"].tap()
        let details = app.buttons["film_render.dir_couplers.details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        if !details.isHittable { controls.swipeUp() }
        details.tap()
        let sliders = app.sliders.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "film_render.dir_couplers."))
        XCTAssertGreaterThan(sliders.count, 1)
        for slider in sliders.allElementsBoundByIndex {
            XCTAssertGreaterThanOrEqual(slider.frame.minX, controls.frame.minX)
            XCTAssertLessThanOrEqual(slider.frame.maxX, controls.frame.maxX)
        }
        controls.swipeUp()
        capture("Dye couplers Details")
    }

    @MainActor func testAdjustmentRangesAndColorOrder() {
        let app = openPhoto()
        app.buttons["editor.tool.adjust"].tap()
        XCTAssertEqual(app.buttons["adjust.section.exposure"].label, "Exposure/Contrast")
        app.buttons["adjust.section.liftGain"].tap()
        let range = app.buttons["adjust.liftGainRange"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        XCTAssertEqual(range.value as? String, "±2")
        range.tap()
        XCTAssertEqual(range.value as? String, "±5")
        let shadow = app.sliders["tone.shadows"]
        drag(shadow, to: 0.95)
        let saved = app.buttons["tone.shadows.value"].value as? String
        XCTAssertNotNil(saved)
        XCTAssertGreaterThan(Double(saved?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0, 2)
        XCTAssertFalse(range.isEnabled, "Narrowing the range would hide the current edit")
        shadow.doubleTap()
        XCTAssertEqual(
            (app.buttons["tone.shadows.value"].value as? String)?.trimmingCharacters(
                in: .whitespaces), "0.0")
        XCTAssertTrue(range.isEnabled)
        range.tap()
        XCTAssertEqual(range.value as? String, "±2")
        if app.buttons["editor.expand"].value as? String == "Collapsed" {
            app.buttons["editor.expand"].tap()
        }
        app.buttons["adjust.section.color"].tap()
        let balance = app.buttons["Print balance"]
        let couplers = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Dye couplers")
        ).firstMatch
        XCTAssertTrue(balance.waitForExistence(timeout: 5))
        XCTAssertLessThan(balance.frame.minY, couplers.frame.minY)
        balance.tap()
        let balanceRange = app.buttons["adjust.balanceRange"]
        XCTAssertTrue(balanceRange.waitForExistence(timeout: 5))
        XCTAssertEqual(balanceRange.value as? String, "±35 CC")
        balanceRange.tap()
        XCTAssertEqual(balanceRange.value as? String, "±100 CC")
        // Let the native title transition settle before visual capture.
        Thread.sleep(forTimeInterval: 0.8)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Shared native range controls"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor func testGroupedPanelsAndSliderReset() {
        let app = openPhoto()
        XCTAssertEqual(app.buttons["editor.expand"].value as? String, "Expanded")
        let compare = app.buttons["editor.compare"]
        XCTAssertGreaterThanOrEqual(compare.frame.minY, app.buttons["editor.info"].frame.maxY)
        XCTAssertTrue(app.buttons["Camera"].exists)
        app.buttons["editor.tool.adjust"].tap()
        drag(app.sliders["tone.exposure"], to: 0.7)
        XCTAssertNotEqual(app.buttons["tone.exposure.value"].value as? String, "0.00 EV")
        app.buttons["editor.history"].tap()
        app.buttons["Undo"].tap()
        XCTAssertEqual(
            app.buttons["tone.exposure.value"].value as? String, "0.00 EV",
            "A drag must undo in one step")
        app.buttons["editor.expand"].tap()
        let contrast = app.sliders["tone.contrast"]
        XCTAssertTrue(contrast.waitForExistence(timeout: 5))
        drag(contrast, to: 0.8)
        XCTAssertNotEqual(
            (app.buttons["tone.contrast.value"].value as? String)?.trimmingCharacters(
                in: .whitespaces), "0.0")
        contrast.doubleTap()
        XCTAssertEqual(
            (app.buttons["tone.contrast.value"].value as? String)?.trimmingCharacters(
                in: .whitespaces), "0.0")
        XCTAssertEqual(app.buttons["editor.expand"].value as? String, "Expanded")
        app.images["Edited photo"].coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.02))
            .tap()
        XCTAssertTrue(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "value == %@", "Collapsed"),
                        object: app.buttons["editor.expand"])
                ], timeout: 3) == .completed)
        app.buttons["adjust.section.liftGain"].tap()
        XCTAssertTrue(app.sliders["tone.shadows"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["tone.highlights"].waitForExistence(timeout: 5))
        XCTAssertLessThan(
            app.sliders["tone.highlights"].frame.minY, app.sliders["tone.shadows"].frame.minY)
        app.buttons["adjust.section.color"].tap()
        let bw = app.descendants(matching: .any).matching(identifier: "tone.monochrome").firstMatch
        XCTAssertTrue(bw.waitForExistence(timeout: 5))
        bw.tap()
        XCTAssertEqual(bw.value as? String, "1")
        app.buttons["editor.tool.effects"].tap()
        let grain = app.descendants(matching: .any).matching(identifier: "grain.monochrome")
            .firstMatch
        XCTAssertTrue(grain.waitForExistence(timeout: 5))
        grain.tap()
        XCTAssertEqual(grain.value as? String, "1")
        app.buttons["effects.section.halation"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "film_render.halation.active")
                .firstMatch
                .waitForExistence(timeout: 5))
        app.buttons["effects.section.diffusion"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "camera.diffusion_filter.active")
                .firstMatch
                .waitForExistence(timeout: 5))
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 30))
    }

    @MainActor func testSourceResetAndDiffusionControls() {
        let app = openPhoto()
        app.buttons["editor.tool.adjust"].tap()
        let exposure = app.sliders["tone.exposure"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 5))
        drag(exposure, to: 0.6)
        let entered = app.buttons["tone.exposure.value"]
        XCTAssertNotEqual(entered.value as? String, "0.00 EV")
        app.buttons["editor.history"].tap()
        app.buttons["Reset All Edits"].tap()
        let reset = app.alerts["Reset all edits?"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.buttons["Reset All Edits"].tap()
        expectation(for: NSPredicate(format: "value == %@", "0.00 EV"), evaluatedWith: entered)
        waitForExpectations(timeout: 10)
        app.buttons["editor.tool.develop"].tap()
        app.buttons["develop.mode.spektrafilm"].tap()
        app.buttons["editor.tool.effects"].tap()
        let area = app.sliders["film_render.grain.particle_area_um2"]
        let areaValue = app.buttons["film_render.grain.particle_area_um2.value"]
        let stockArea = areaValue.value as? String
        drag(area, to: 0.5)
        XCTAssertNotEqual(areaValue.value as? String, stockArea)
        app.buttons["grain.stockDefaults"].tap()
        let resetButtons = app.buttons.matching(identifier: "Use Stock Grain")
        resetButtons.element(boundBy: resetButtons.count - 1).tap()
        XCTAssertEqual(areaValue.value as? String, stockArea)
        XCTAssertLessThan(
            app.buttons["grain.stockDefaults"].frame.maxY,
            app.buttons["film_render.grain.details"].frame.minY)
        app.buttons["effects.section.halation"].tap()
        let scatter = app.buttons["film_render.halation.scatter_amount.value"]
        XCTAssertEqual(scatter.value as? String, "100 %")
        let halation = app.sliders["film_render.halation.halation_amount"]
        drag(halation, to: 0.8)
        let amount =
            app.buttons["film_render.halation.halation_amount.value"].value as? String ?? ""
        XCTAssertGreaterThan(Double(amount.split(separator: " ").first ?? "0") ?? 0, 20)
        app.buttons["effects.section.diffusion"].tap()
        for key in ["camera.diffusion_filter.active", "enlarger.diffusion_filter.active"] {
            let toggle = app.descendants(matching: .any).matching(identifier: key).firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            for _ in 0..<8 {
                let controls = app.scrollViews["editor.controls"].frame
                let top = controls.minY + 12
                let bottom = controls.maxY - 12
                if toggle.isHittable && toggle.frame.minY >= top && toggle.frame.maxY <= bottom {
                    break
                }
                let upwards = toggle.frame.midY > (top + bottom) / 2
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(
                    CGVector(dx: app.frame.midX, dy: upwards ? bottom : top))
                let end = origin.withOffset(CGVector(dx: app.frame.midX, dy: (top + bottom) / 2))
                start.press(
                    forDuration: 0.05, thenDragTo: end, withVelocity: .slow,
                    thenHoldForDuration: 0.2)
            }
            XCTAssertTrue(toggle.isHittable, app.debugDescription)
            toggle.tap()
            XCTAssertEqual(toggle.value as? String, "1")
            XCTAssertLessThanOrEqual(toggle.frame.maxX, app.frame.maxX)
        }
        let busy = app.progressIndicators["Rendering preview"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: busy)
        waitForExpectations(timeout: 30)
        XCTAssertFalse(app.staticTexts["Couldn’t update preview"].exists)
        XCTAssertTrue(app.buttons["editor.back"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Both diffusion stages enabled"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor func testExportOptionsAndCancellation() {
        let app = openPhoto()
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.buttons["S"].waitForExistence(timeout: 5))
        app.buttons["S"].tap()
        app.buttons["PNG"].tap()
        app.buttons["JPEG"].tap()
        app.buttons["Standard"].tap()
        let save = app.buttons["export.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 45))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 45)
        XCTAssertTrue(save.isHittable, "Default export layout hid Save to Photos")
        XCTAssertTrue(app.buttons["export.share"].isHittable)
        XCTAssertGreaterThan(
            app.buttons["Done"].frame.minY, app.frame.height * 0.15, "Export opened at full height")
        let dimensionRow = app.descendants(matching: .any)["export.dimensions"]
        XCTAssertTrue(dimensionRow.isHittable)
        let dimensionText = ([dimensionRow.label, dimensionRow.value as? String ?? ""]
            + dimensionRow.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " ")
        let dimensions = dimensionText.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
        XCTAssertGreaterThanOrEqual(dimensions.count, 2)
        XCTAssertTrue(dimensions.allSatisfy { (1...1080).contains($0) }, "Small exports must not exceed 1080 or upscale a small fixture")
        XCTAssertLessThan(dimensionRow.frame.maxY, save.frame.minY)
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "needs more rendering memory")
            )
            .firstMatch.exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Native export options"
        image.lifetime = .keepAlways
        add(image)
    }

}
