#if DEBUG || PERFORMANCE_CHECKS
import CryptoKit
import Foundation
import ImageIO
import UIKit

/// Explicit, read-only photo validation. All test recipes are in-memory copies; only
/// diagnostic PNGs/JSON are written to Caches. No library save callback or Photos writes.
@MainActor enum DarkroomOrientationChecks {
    static func run(_ library: PhotoLibrary) async {
        guard ProcessInfo.processInfo.arguments.contains("--check-darkroom-orientation") else { return }
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let folder = URL.cachesDirectory.appendingPathComponent("DarkroomOrientationChecks")
        let reportURL = folder.appendingPathComponent("report.json")
        var report: [String: Any] = ["status": "running", "started": Date().ISO8601Format(),
            "scope": "Real-file Crop/session/preview/PNG export on device; no source, recipe, preference or Photos changes."]
        var rows: [[String: Any]] = []
        func checkpoint() {
            report["cases"] = rows
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        checkpoint()
        await library.images.beginExport()
        do {
            var selected: [LibraryPhoto] = [], groups = Set<String>()
            for photo in library.photos {
                let data = try Data(contentsOf: library.files.sourceURL(photo), options: .mappedIfSafe)
                guard let description = PhotoSource.describe(data, typeHint: PhotoSource.typeHint(for: library.files.sourceURL(photo))) else { continue }
                let group = "\(photo.fileExtension)-\(description.width < description.height)-\(description.width == description.height)"
                if groups.insert(group).inserted { selected.append(photo) }
            }
            for photo in library.photos where selected.count < 8 && !selected.contains(where: { $0.id == photo.id }) {
                selected.append(photo)
            }
            report["expectedCount"] = min(selected.count, 8)
            for (index, photo) in selected.prefix(8).enumerated() {
                rows.append(try await check(photo, index: index, library: library, folder: folder))
                checkpoint()
            }
            guard !rows.isEmpty else { throw PhotoExporter.Failure.decode }
            report["status"] = "PASS"
        } catch {
            report["status"] = "FAIL"
            report["error"] = String(describing: error)
        }
        await library.images.endExport()
        report["finished"] = Date().ISO8601Format()
        checkpoint()
    }

    private static func check(_ photo: LibraryPhoto, index: Int, library: PhotoLibrary, folder: URL) async throws -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        let original = try Data(contentsOf: library.files.sourceURL(photo), options: .mappedIfSafe)
        let digest = SHA256.hash(data: original)
        guard let imported = ImportedPhoto.decode(original, maximum: 1080, typeHint: PhotoSource.typeHint(for: library.files.sourceURL(photo))),
              let description = imported.sourceDescription else { throw PhotoExporter.Failure.decode }
        let native = CGSize(width: imported.width, height: imported.height)
        let aspect = Double(imported.preview.width) / Double(imported.preview.height)
        guard abs(log(aspect / (native.width / native.height))) < 0.005 else { throw CheckFailure.dimensions }
        var recipe = EditorDefaults.originalRecipe(temperature: imported.rawTemperature)
        recipe.look.enabled = true
        recipe.filmEdgeLayout = FilmEdgeLayout()
        let session = EditorSession(photo: imported, recipe: recipe, resources: library.images.resources)
        defer { session.cancelRendering() }
        let crop = session.recipe.crop.pixelRect(in: native)
        let portrait = crop.height > crop.width
        guard portrait == (native.height > native.width) else { throw CheckFailure.crop }
        let preview = try await session.filmEdgePreview(session.recipe, maximum: 720)
        guard (preview.height > preview.width) == portrait else { throw CheckFailure.preview }
        var paper = PrintLayout(); paper.paper = .fourBySix
        session.update(key: "darkroom.layout") { $0.printLayout = paper }
        let paperGeometry = PrintGeometry(imageSize: CGSize(width: preview.width, height: preview.height), layout: paper, longEdge: 1080)!
        guard (paperGeometry.paperSize.height > paperGeometry.paperSize.width) == portrait else { throw CheckFailure.paper }
        let exported = try await session.export(size: .small, format: .png, quality: 1)
        guard (exported.2 > exported.1) == portrait else { throw CheckFailure.export }
        let resultURL = folder.appendingPathComponent("case-\(index + 1).png")
        try? FileManager.default.removeItem(at: resultURL)
        try FileManager.default.moveItem(at: exported.0, to: resultURL)
        guard digest == SHA256.hash(data: try Data(contentsOf: library.files.sourceURL(photo))),
              library.photo(photo.id)?.recipeData == photo.recipeData else { throw CheckFailure.preservation }
        let properties = PhotoSource.imageSource(original).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        return ["case": index + 1, "type": description.type, "raw": imported.rawTemperature != nil,
            "exifOrientation": properties?[kCGImagePropertyOrientation] as? Int ?? 1,
            "native": [imported.width, imported.height], "preview": [preview.width, preview.height],
            "crop": [crop.width, crop.height], "export": [exported.1, exported.2],
            "portrait": portrait, "sourceUnchanged": true, "savedRecipeUnchanged": true,
            "milliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000]
    }
    private enum CheckFailure: Error { case dimensions, crop, preview, paper, export, preservation }
}
#endif
