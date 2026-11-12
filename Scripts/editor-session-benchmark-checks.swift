import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Exercise the real UI session scheduler using a process-local preview preference.
@main struct EditorSessionChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain([PreviewQuality.editorKey: 2160], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let context = CGContext(data: nil, width: 1024, height: 768, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0,y: 0,width: 1024,height: 768))
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let photo = ImportedPhoto.decode(encoded as Data)!
        let resources = FilmRenderResources(directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"))
        var saved = EditRecipe()
        saved.flags["film_render.grain.active"] = false
        let restored = EditorSession(photo: photo, recipe: saved, resources: resources)
        let entryImage = restored.displayImage
        restored.resumeRendering()
        for _ in 0..<3000 {
            if restored.displayImage !== entryImage { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        precondition(restored.displayImage !== entryImage && restored.effectivePreviewMaximum == 720,
            "Saved editor entry skipped the quick first preview")
        restored.cancelRendering()
        let session = EditorSession(photo: photo, resources: resources)
        session.resumeRendering()
        precondition(!session.hasEdits && !session.recipe.look.enabled && !session.isProcessingFilm,
            "Neutral entry unexpectedly started a film render or saved an edit")
        let unchangedPreview = session.displayImage
        session.setPresentationInteraction(key: "darkroom.layout", active: true)
        for value in [0.8, 0.6] {
            session.update(key: "darkroom.layout") {
                var layout = PrintLayout()
                layout.paper = .eightByTen
                layout.scale = value
                $0.printLayout = layout
            }
            try await Task.sleep(for: .milliseconds(450))
        }
        session.setPresentationInteraction(key: "darkroom.layout", active: false)
        precondition(!session.isProcessingFilm && session.displayImage === unchangedPreview)
        session.undo()
        precondition(session.recipe.printLayout == nil && !session.canUndo && !session.isProcessingFilm,
            "A finishing gesture split its undo group or restarted film processing")
        session.redo()
        precondition(session.recipe.printLayout?.scale == 0.6 && !session.isProcessingFilm)
        session.undo()
        session.update(key: "look.mode") { $0.look.enabled = true; $0.flags["film_render.grain.active"] = false }
        func waitForIdle() async throws {
            for _ in 0..<2000 {
                if !session.isProcessingFilm { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("Session render did not settle")
        }
        try await waitForIdle()
        let started = ProcessInfo.processInfo.systemUptime
        session.setInteraction(key: "tone.exposure", active: true)
        for value in [0.1,0.2,0.3,0.4,0.5] {
            session.update(key: "tone.exposure") { $0.tone.exposureEV = value }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await waitForIdle()
        precondition(session.effectivePreviewMaximum == 720 && !session.isBusy && !session.filmRenderFailed,
            "Interactive preview did not complete at its bounded size")
        let dragMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        session.setInteraction(key: "tone.exposure", active: false)
        // A second touch inside the quiet interval cancels only the queued refinement.
        try await Task.sleep(for: .milliseconds(40))
        session.setInteraction(key: "tone.exposure", active: true)
        session.update(key: "tone.exposure") { $0.tone.exposureEV = 0.75 }
        try await waitForIdle()
        precondition(session.effectivePreviewMaximum == 720 && !session.filmRenderFailed)
        session.setInteraction(key: "tone.exposure", active: false)
        try await Task.sleep(for: .milliseconds(200))
        if session.isRefiningPreview { precondition(!session.isBusy, "Quality refinement blocked an already-current preview") }
        try await waitForIdle()
        precondition(session.effectivePreviewMaximum == 2160 && !session.isBusy && !session.filmRenderFailed)
        session.undo()
        precondition(session.recipe.tone.exposureEV == 0.5, "Second gesture did not undo in one step")
        try await waitForIdle()
        let exported = try await session.export(size: .small, format: .png, quality: 1)
        precondition(exported.1 == 1024 && exported.2 == 768)
        try FileManager.default.removeItem(at: exported.0)
        session.resumeAfterExport()
        try await waitForIdle()
        precondition(session.hasFilmPreview && !session.filmRenderFailed && !session.isBusy,
            "Returning from export left the editor waiting")
        session.update(key: "darkroom.layout") {
            var layout = PrintLayout()
            layout.paper = .eightByTen
            layout.scale = 0.8
            $0.printLayout = layout
        }
        let printed = try await session.export(size: .small, format: .png, quality: 1)
        precondition(printed.1 == 1024 && printed.2 == 819,
            "Session export ignored the saved paper geometry or exceeded its pixel budget")
        let printedSource = CGImageSourceCreateWithURL(printed.0 as CFURL, nil)!
        let printedImage = CGImageSourceCreateImageAtIndex(printedSource, 0, nil)!
        precondition(printedImage.bitsPerComponent == 8 && printedImage.colorSpace?.model == .rgb)
        try FileManager.default.removeItem(at: printed.0)
        session.update(key: "darkroom.layout") { $0.printLayout = nil }
        session.resumeAfterExport()
        try await waitForIdle()
        session.cancelRendering()
        precondition(!session.isProcessingFilm && !session.isBusy)
        UserDefaults.standard.setVolatileDomain([
            PreviewQuality.editorKey: 2160, EditorDefaults.grainKey: false,
            EditorDefaults.halationKey: false, EditorDefaults.monochromeGrainKey: true,
        ], forName: UserDefaults.argumentDomain)
        let defaults = EditorSession(photo: photo, resources: resources)
        precondition(!defaults.hasEdits && !defaults.recipe.flag("film_render.grain.active")
            && !defaults.recipe.flag("film_render.halation.active") && defaults.recipe.monochromeGrain)
        let existing = EditorSession(photo: photo, recipe: EditRecipe(), resources: resources)
        precondition(existing.recipe.flag("film_render.grain.active")
            && existing.recipe.flag("film_render.halation.active") && !existing.recipe.monochromeGrain,
            "New-edit defaults changed a saved recipe")
        UserDefaults.standard.setVolatileDomain([PreviewQuality.editorKey: 2160], forName: UserDefaults.argumentDomain)
        precondition(!defaults.hasEdits, "Preference changes marked an untouched photo edited")
        defaults.update(key: "tone.exposure") { $0.tone.exposureEV = 0.2 }
        defaults.resetAll()
        precondition(!defaults.hasEdits && !defaults.recipe.flag("film_render.grain.active"))
        defaults.cancelRendering()
        existing.cancelRendering()
        print("PASS: new-edit effect defaults, unchanged saved recipes and stable Original/reset state")
        print("PASS: saved entry first shows 720; neutral entry does no film work; rapid edits stay at 720; interrupted settling resumes high quality; one-step undo; export return; cancellation. Drag sequence ms", dragMS)
        try await checkLargeLUTSession(resources: resources)
        let cropSession = EditorSession(photo: photo, resources: resources)
        let originalCrop = cropSession.recipe.crop
        cropSession.update(key: "darkroom.edge.layout") { $0.filmEdgeLayout = FilmEdgeLayout() }
        precondition(cropSession.recipe.crop.aspect == .threeTwo)
        precondition(abs(cropSession.recipe.crop.normalizedRect.height - 8.0 / 9) < 1e-9)
        cropSession.undo()
        precondition(cropSession.recipe.filmEdgeLayout == nil && cropSession.recipe.crop == originalCrop && !cropSession.canUndo,
            "Edge activation and its required crop did not undo together")
        cropSession.redo()
        cropSession.update(key: "crop") { $0.crop = CropSelection() }
        precondition(cropSession.recipe.crop.aspect == .threeTwo, "An active film gate accepted a free crop")
        cropSession.cancelRendering()
        print("PASS: required gate crop and activation share one undo; reset/free edits stay within the fixed aperture")
        var edged = saved
        edged.look.enabled = true
        edged.filmEdgeLayout = FilmEdgeLayout()
        let darkroom = EditorSession(photo: photo, recipe: edged, resources: resources)
        let edgeStart = ProcessInfo.processInfo.systemUptime
        let firstEdge = try await darkroom.filmEdgePreview(edged, maximum: 720)
        precondition(max(firstEdge.width, firstEdge.height) == 720)
        let edgeMS = (ProcessInfo.processInfo.systemUptime - edgeStart) * 1000
        darkroom.update(key: "darkroom.edge.selection") {
            var selection = FilmEdgeSelection(); selection.mode = .manual; selection.manualType = .reversalScan
            $0.filmEdgeSelection = selection
        }
        precondition(!darkroom.isProcessingFilm, "Finishing restarted the Develop scheduler")
        darkroom.undo()
        precondition(darkroom.recipe.filmEdgeSelection == nil && darkroom.recipe.filmEdgeLayout != nil)
        darkroom.redo()
        precondition(darkroom.recipe.resolvedFilmEdgeType == .reversalScan)
        let stale = Task { try await darkroom.filmEdgePreview(darkroom.recipe, maximum: 2160) }
        await Task.yield()
        let result = try await darkroom.export(size: .small, format: .png, quality: 1)
        try? FileManager.default.removeItem(at: result.0)
        _ = await stale.result
        precondition(result.1 == 1024 && result.2 > 0, "Export after preview cancellation lost the edge")
        darkroom.cancelRendering()
        print("PASS: native Darkroom preview, finishing undo/redo without Develop work, preview→export cancellation handoff. First 720 edge ms", edgeMS)
    }

    /// Cross the strip-grading threshold with grain enabled, then return to the drag cache.
    @MainActor private static func checkLargeLUTSession(resources: FilmRenderResources) async throws {
        let context = CGContext(data: nil, width: 2160, height: 1620, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2160, height: 1620))
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let photo = ImportedPhoto.decode(encoded as Data)!
        var recipe = EditRecipe()
        recipe.look.mode = .lut
        recipe.flags["film_render.halation.active"] = false
        let session = EditorSession(photo: photo, recipe: recipe, resources: resources)
        defer { session.cancelRendering() }
        func idle() async throws {
            for _ in 0..<3000 {
                if !session.isProcessingFilm && !session.isRendering {
                    precondition(!session.filmRenderFailed && !session.renderFailed)
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("2160 grain session did not settle")
        }
        session.resumeRendering()
        try await Task.sleep(for: .milliseconds(200))
        try await idle()
        precondition(session.displayImage.size == CGSize(width: 2160, height: 1620))
        for value in [0.1, 0.2, 0.3] {
            session.setInteraction(key: "tone.exposure", active: true)
            session.update(key: "tone.exposure") { $0.tone.exposureEV = value }
            try await idle()
            precondition(session.effectivePreviewMaximum == 720)
            session.setInteraction(key: "tone.exposure", active: false)
            try await Task.sleep(for: .milliseconds(200))
            try await idle()
            precondition(session.displayImage.size == CGSize(width: 2160, height: 1620))
        }
        print("PASS: grain-enabled 2160 LUT session settles and returns to 720 dragging across three quality changes")
    }
}
