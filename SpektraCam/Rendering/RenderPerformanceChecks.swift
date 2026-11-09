#if DEBUG || PERFORMANCE_CHECKS
import CryptoKit
import Darwin
import Foundation
import Metal
import os
import UIKit

/// Explicit local benchmark; never changes a photo, recipe or Photos asset.
@MainActor enum RenderPerformanceChecks {
    static func run(_ library: PhotoLibrary) async {
        let arguments = ProcessInfo.processInfo.arguments
        // Separate, explicit setup action for a developer-authorized device preference change.
        if let index = arguments.firstIndex(of: "--set-preview-maximum"), index + 1 < arguments.count,
            let maximum = Int(arguments[index + 1]), PreviewQuality.choices.contains(maximum)
        {
            UserDefaults.standard.set(maximum, forKey: PreviewQuality.libraryKey)
            UserDefaults.standard.set(maximum, forKey: PreviewQuality.editorKey)
            try? JSONSerialization.data(withJSONObject: ["library": PreviewQuality.libraryMaximum,
                "editor": PreviewQuality.editorMaximum]).write(to:
                    URL.cachesDirectory.appendingPathComponent("configured-preview-quality.json"), options: .atomic)
            return
        }
        let requestedPhoto = arguments.firstIndex(of: "--performance-photo").flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        }
        guard arguments.contains("--check-performance"),
            let photo = requestedPhoto.flatMap { requested in
                library.photos.first { $0.id.uuidString.caseInsensitiveCompare(requested) == .orderedSame }
            } ?? library.photos.first(where: \.isRAW) ?? library.photos.first
        else { return }
        let label = arguments.firstIndex(of: "--performance-run").flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        } ?? "run"
        if arguments.contains("--performance-sliders") {
            await checkEditor(library, photo: photo, label: label)
            return
        }
        var rows: [[String: Any]] = []
        let started = Date()
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        var report: [String: Any] = [
            "label": label, "started": started.ISO8601Format(),
            "sourceID": photo.id.uuidString, "raw": photo.isRAW,
            "nativeDimensions": [photo.metadata.width, photo.metadata.height],
            "hasEdits": photo.hasEdits,
            "thermalStart": thermal,
        ]
        func time(_ name: String, _ work: () async throws -> Void) async throws {
            let start = ProcessInfo.processInfo.systemUptime
            try await work()
            rows.append([
                "name": name,
                "milliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                "availableMB": os_proc_available_memory() / 1_048_576,
                "metalMB": (MTLCreateSystemDefaultDevice()?.currentAllocatedSize ?? 0) / 1_048_576,
            ])
        }
        await library.images.beginExport()
        do {
            var imported: ImportedPhoto!
            try await time("open.decode1080") {
                imported = try await library.files.decodedPhoto(photo, maximum: 1080)
            }
            let digest = SHA256.hash(data: imported.data)
            try await time("open.cachedDevelop1080") {
                imported = try await library.files.decodedPhoto(photo, maximum: 1080)
            }
            let directory = Bundle.main.resourceURL!
            var renderer: PhotoRenderer!
            try await time("editor.init") {
                renderer = PhotoRenderer(
                    source: imported.preview, directory: directory, data: imported.data,
                    temperature: imported.rawTemperature, previewMaximum: 1080,
                    resources: library.images.resources, sourceType: imported.sourceType,
                    description: imported.sourceDescription)
            }
            var recipe = EditRecipe()
            recipe.temperature = imported.rawTemperature
            try await time("editor.firstFilm1080") { _ = try await renderer.render(recipe) }
            for repeatIndex in 0..<3 {
                recipe.mix = 0.5
                try await time("mix.half1080.\(repeatIndex)") { _ = try await renderer.render(recipe) }
                recipe.mix = 1
                try await time("mix.full1080.\(repeatIndex)") { _ = try await renderer.render(recipe) }
            }
            for repeatIndex in 0..<3 {
                recipe.mix = 0.5
                try await time("resolution.drag720.\(repeatIndex)") {
                    _ = try await renderer.render(recipe, maximum: 720)
                }
                try await time("resolution.settle1080.\(repeatIndex)") {
                    _ = try await renderer.render(recipe, maximum: 1080)
                }
            }
            recipe.mix = 1
            for value in [0.25, 0.5, 0.75] {
                recipe.source.exposureEV = value
                try await time("raw.exposure720.\(value)") {
                    _ = try await renderer.render(recipe, maximum: 720)
                }
            }
            recipe = EditRecipe(); recipe.temperature = imported.rawTemperature
            let shared = library.images.resources
            for repeatIndex in 0..<2 {
                try await time("editor.sharedReopen1080.\(repeatIndex)") {
                    let next = PhotoRenderer(
                        source: imported.preview, directory: directory, data: imported.data,
                        temperature: imported.rawTemperature, previewMaximum: 1080,
                        resources: shared, sourceType: imported.sourceType,
                        description: imported.sourceDescription)
                    _ = try await next.render(recipe)
                }
            }
            guard digest == SHA256.hash(data: try Data(contentsOf: library.files.sourceURL(photo)))
            else { throw PhotoExporter.Failure.render }
            report["sourceHash"] = digest.map { String(format: "%02x", $0) }.joined()
            if ProcessInfo.processInfo.arguments.contains("--performance-check-grain") {
                report["grainSampling"] = try await checkGrainSampling()
            }
            report["result"] = "PASS"
        } catch {
            report["result"] = "FAIL"
            report["error"] = error.localizedDescription
        }
        await library.images.endExport()
        report["measurements"] = rows
        report["thermalEnd"] = ProcessInfo.processInfo.thermalState.rawValue
        report["finished"] = Date().ISO8601Format()
        report["scope"] = "Wall time for actual RAW import and rendering; excludes UI presentation latency. Cache-only test files; source unchanged."
        let safeLabel = label.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL.cachesDirectory.appendingPathComponent("performance-\(safeLabel).json"), options: .atomic)
    }

    /// Opt-in device measurements using an in-memory copy of the saved recipe.
    /// No save callback is attached; measured changes never enter the library.
    private static func checkEditor(_ library: PhotoLibrary, photo: LibraryPhoto, label: String) async {
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        var rows: [[String: Any]] = []
        let safeLabel = label.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let reportURL = URL.cachesDirectory.appendingPathComponent("performance-\(safeLabel).json")
        var report: [String: Any] = [
            "label": label, "started": Date().ISO8601Format(),
            "sourceID": photo.id.uuidString, "raw": photo.isRAW,
            "nativeDimensions": [photo.metadata.width, photo.metadata.height],
            "editorMaximum": PreviewQuality.editorMaximum,
            "thermalStart": ProcessInfo.processInfo.thermalState.rawValue,
            "scope": "Renderer/session processing, excluding touch delivery and screen presentation. Current memory is sampled at stage boundaries; footprintPeakMB is the kernel process-lifetime peak.",
        ]
        #if DEBUG
            report["configuration"] = "Debug"
        #else
            report["configuration"] = "Release"
        #endif
        func checkpoint(_ phase: String) {
            report["phase"] = phase
            report["applicationState"] = UIApplication.shared.applicationState.rawValue
            report["measurements"] = rows
            if report["result"] == nil { report["result"] = "RUNNING" }
            do {
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: reportURL, options: .atomic)
            } catch { print("Measurement report error: \(error)") }
            print("MEASUREMENT \(label): \(phase)")
            fflush(stdout)
        }
        func sample() -> [String: Any] {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return [
                "availableMB": os_proc_available_memory() / 1_048_576,
                "footprintMB": status == KERN_SUCCESS ? info.phys_footprint / 1_048_576 : 0,
                "footprintPeakMB": status == KERN_SUCCESS ? max(0, info.ledger_phys_footprint_peak) / 1_048_576 : 0,
                "metalMB": (MTLCreateSystemDefaultDevice()?.currentAllocatedSize ?? 0) / 1_048_576,
            ]
        }
        func time(_ name: String, _ work: () async throws -> Void) async throws {
            guard UIApplication.shared.applicationState == .active else { throw CheckFailure.inactive }
            checkpoint(name + ".begin")
            let before = sample(), started = ProcessInfo.processInfo.systemUptime
            try await work()
            guard UIApplication.shared.applicationState == .active else { throw CheckFailure.inactive }
            rows.append(["name": name, "milliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                "before": before, "after": sample()])
            checkpoint(name + ".complete")
        }
        checkpoint("starting")
        // The view's startup task can precede the scene's first active transition.
        // Do not time that transition or mistake it for the user leaving the app.
        for _ in 0..<1000 {
            if UIApplication.shared.applicationState == .active || Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard !Task.isCancelled else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        var session: EditorSession?
        do {
            var imported: ImportedPhoto!
            try await time("source.decode") {
                imported = try await library.files.decodedPhoto(photo, maximum: PreviewQuality.editorMaximum)
            }
            let digest = SHA256.hash(data: imported.data)
            var recipe = try library.recipe(photo.id) ?? EditRecipe()
            report["savedLook"] = recipe.look.mode.rawValue
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--performance-mode"), index + 1 < arguments.count,
                let mode = EditRecipe.LookMode(rawValue: arguments[index + 1])
            {
                recipe.look.mode = mode
                recipe.look.enabled = true
            }
            if recipe.temperature == nil { recipe.temperature = imported.rawTemperature }
            report["testedLook"] = recipe.look.mode.rawValue
            report["grainEnabled"] = recipe.flag("film_render.grain.active")
            let editor = EditorSession(photo: imported, recipe: recipe, luts: library.luts,
                resources: library.images.resources, sourceFilename: photo.filename)
            session = editor
            let work = await library.images.workSnapshot()
            report["libraryWorkBeforeEditor"] = ["active": work.active, "consumers": work.consumers]
            try await time("editor.takeRenderOwnership") {
                await library.images.beginEditing(owner: editor.id)
            }
            func idle() async throws {
                for _ in 0..<3000 {
                    guard UIApplication.shared.applicationState == .active else { throw CheckFailure.inactive }
                    if !editor.isProcessingFilm && !editor.isRendering {
                        guard !editor.filmRenderFailed && !editor.renderFailed else { throw CheckFailure.preview }
                        return
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw CheckFailure.timeout
            }
            func changedPreview(from previous: AnyObject) async throws {
                for _ in 0..<3000 {
                    guard UIApplication.shared.applicationState == .active else { throw CheckFailure.inactive }
                    if editor.displayImage !== previous { return }
                    if editor.filmRenderFailed || editor.renderFailed { throw CheckFailure.preview }
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw CheckFailure.timeout
            }
            let entryImage = editor.displayImage
            try await time("editor.enterFirstPreview") {
                editor.resumeRendering()
                try await changedPreview(from: entryImage)
            }
            report["entryFirstMaximum"] = editor.effectivePreviewMaximum
            try await time("editor.finishEntryRefinement") {
                try await Task.sleep(for: .milliseconds(200))
                try await idle()
            }
            let baseExposure = recipe.tone.exposureEV
            editor.setInteraction(key: "tone.exposure", active: true)
            for (index, offset) in [0.1, 0.2, 0.3, 0.4, 0.5].enumerated() {
                try await time("tone.drag720.\(index)") {
                    editor.update(key: "tone.exposure") { $0.tone.exposureEV = baseExposure + offset }
                    try await idle()
                }
            }
            try await time("tone.continuous20x16ms") {
                for index in 0..<20 {
                    editor.update(key: "tone.exposure") { $0.tone.exposureEV = baseExposure + Double(index) / 40 }
                    try await Task.sleep(for: .milliseconds(16))
                }
                try await idle()
            }
            report["dragMaximum"] = editor.effectivePreviewMaximum
            try await time("tone.settleConfiguredIncluding180msDelay") {
                editor.setInteraction(key: "tone.exposure", active: false)
                try await Task.sleep(for: .milliseconds(200))
                try await idle()
            }
            report["settledMaximum"] = editor.effectivePreviewMaximum
            try await time("source.drag720") {
                editor.setInteraction(key: "source.exposure", active: true)
                editor.update(key: "source.exposure") { $0.source.exposureEV += 0.1 }
                try await idle()
                editor.setInteraction(key: "source.exposure", active: false)
            }
            let fullExport = ProcessInfo.processInfo.arguments.contains("--performance-export-full")
            do {
                try await time(fullExport ? "export.prepareNative" : "export.prepare1080") {
                    await library.images.beginExport()
                    do {
                        let file = try await editor.export(size: fullExport ? .full : .small, format: .jpeg, quality: 0.9)
                        report["exportDimensions"] = [file.1, file.2]
                        try FileManager.default.removeItem(at: file.0)
                    } catch {
                        await library.images.endExport()
                        throw error
                    }
                    await library.images.endExport()
                }
            } catch let failure as RenderMemoryBudget.Failure where fullExport {
                report["fullExportAdmission"] = failure.localizedDescription
            }
            let exportedPreview = editor.displayImage
            try await time("export.returnFirstPreview") {
                editor.resumeAfterExport()
                try await changedPreview(from: exportedPreview)
            }
            report["exportReturnFirstMaximum"] = editor.effectivePreviewMaximum
            try await idle()
            guard digest == SHA256.hash(data: try Data(contentsOf: library.files.sourceURL(photo)))
            else { throw CheckFailure.original }
            report["sourceHash"] = digest.map { String(format: "%02x", $0) }.joined()
            if ProcessInfo.processInfo.arguments.contains("--performance-check-grain") {
                checkpoint("sampling.begin")
                report["grainSampling"] = try await checkGrainSampling()
                checkpoint("sampling.complete")
            }
            if ProcessInfo.processInfo.arguments.contains("--performance-save-preview") {
                guard UIApplication.shared.applicationState == .active else { throw CheckFailure.inactive }
                editor.cancelRendering()
                let renderer = PhotoRenderer(source: imported.preview, directory: Bundle.main.resourceURL!,
                    data: imported.data, temperature: imported.rawTemperature,
                    lutDirectory: library.luts.directory, resources: library.images.resources,
                    sourceType: imported.sourceType, description: imported.sourceDescription)
                let safe = label.filter { $0.isLetter || $0.isNumber || $0 == "-" }
                let directory = URL.cachesDirectory.appendingPathComponent("EditorPerformance-" + safe)
                var files: [String] = []
                for active in [false, true] {
                    guard UIApplication.shared.applicationState == .active else { throw CheckFailure.inactive }
                    var controlled = recipe
                    controlled.flags["film_render.grain.active"] = active
                    controlled.monochromeGrain = false
                    checkpoint(active ? "grain-preview-color.render" : "grain-preview-off.render")
                    let image = try await renderer.render(controlled, maximum: PreviewQuality.editorMaximum)
                    guard UIApplication.shared.applicationState == .active else { throw CheckFailure.inactive }
                    checkpoint(active ? "grain-preview-color.encode" : "grain-preview-off.encode")
                    let url = try PhotoExporter.write(image, format: .png, directory: directory,
                        sourceFilename: active ? "grain-color.png" : "grain-off.png")
                    files.append(String(url.path.dropFirst(URL.cachesDirectory.path.count + 1)))
                }
                report["previewFiles"] = files
            }
            report["result"] = "PASS"
        } catch {
            report["result"] = "FAIL"
            report["error"] = String(describing: error)
        }
        session?.cancelRendering()
        if let session { await library.images.endEditing(owner: session.id) }
        report["measurements"] = rows
        report["thermalEnd"] = ProcessInfo.processInfo.thermalState.rawValue
        report["finished"] = Date().ISO8601Format()
        checkpoint("finished")
    }
    private static func checkGrainSampling() async throws -> [[String: Any]] {
        let sampler = try MetalGrain(source: String(contentsOf:
            Bundle.main.resourceURL!.appendingPathComponent("Grain.metalSource"), encoding: .utf8))
        let count = 100_000
        let input = Array(repeating: SIMD4<Float>(0.5, 0.5, 0.5, 0), count: count)
        var sampling: [[String: Any]] = []
        for lambda in [0.01, 5, 30, 10000] {
            let pixels = try await sampler.particles(input, maximum: .init(repeating: 1),
                particles: .init(repeating: Float(2 * lambda)), uniformity: .zero, seed: 20_261_108)
            for ch in 0..<3 {
                let bias = pixels.reduce(0.0) { $0 + Double($1[ch]) - 0.5 } / Double(count)
                let expectedVariance = 1 / (4 * lambda)
                let variance = pixels.reduce(0.0) { $0 + pow(Double($1[ch]) - 0.5 - bias, 2) } / Double(count)
                sampling.append(["lambda": lambda, "channel": ch, "bias": bias,
                    "relativeVariance": variance / expectedVariance])
                guard abs(bias) < 8 * sqrt(expectedVariance / Double(count)) + Double(Float(0.5).ulp),
                    abs(variance / expectedVariance - 1) < 8 * sqrt((2 + 1 / lambda) / Double(count)) + 0.005
                else { throw CheckFailure.sampling }
            }
        }
        return sampling
    }
    private enum CheckFailure: Error { case preview, timeout, original, sampling, inactive }
}
#endif
