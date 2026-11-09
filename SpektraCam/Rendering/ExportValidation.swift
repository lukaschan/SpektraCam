#if DEBUG || PERFORMANCE_CHECKS
    import Foundation
    import Metal
    import ImageIO
    import os
    import CoreGraphics
    import CoreImage
    import CryptoKit

    /// Explicit launch-only check. Reads an app copy and writes a temporary report; never edits its recipe.
    @MainActor enum ExportValidation {
        /// Explicit read-only device check. Results and rendered files stay in disposable caches.
        static func checkSDR(_ library: PhotoLibrary) async {
            guard ProcessInfo.processInfo.arguments.contains("--check-sdr") else { return }
            let context = CIContext(options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
            ])
            func pixels(_ image: CGImage) -> [SIMD4<Float>] {
                var values = [SIMD4<Float>](repeating: .zero, count: image.width * image.height)
                values.withUnsafeMutableBytes {
                    context.render(
                        CIImage(cgImage: image), toBitmap: $0.baseAddress!,
                        rowBytes: image.width * 16,
                        bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                        format: .RGBAf,
                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                }
                return values
            }
            let chosen = [
                library.photos.first(where: \.isRAW),
                library.photos.first {
                    !$0.isRAW && $0.fileExtension.lowercased().hasPrefix("hei")
                },
                library.photos.first {
                    !$0.isRAW && !$0.fileExtension.lowercased().hasPrefix("hei")
                },
            ]
            .compactMap { $0 }
            var report: [String: Any] = [
                "started": Date().ISO8601Format(), "libraryCount": library.photos.count,
            ]
            var cases: [[String: Any]] = []
            let resources = library.images.resources
            let device = MTLCreateSystemDefaultDevice()
            let sampler = Task { () -> (UInt64, Int) in
                var minimum = UInt64(os_proc_available_memory())
                var peakGPU = device?.currentAllocatedSize ?? 0
                while !Task.isCancelled {
                    minimum = min(minimum, UInt64(os_proc_available_memory()))
                    peakGPU = max(peakGPU, device?.currentAllocatedSize ?? 0)
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
                }
                return (minimum, peakGPU)
            }
            let folder = URL.cachesDirectory.appendingPathComponent("SDRDeviceChecks")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            await library.images.beginExport()
            for photo in chosen {
                if Task.isCancelled { break }
                var item: [String: Any] = [
                    "id": photo.id.uuidString, "raw": photo.isRAW,
                    "sourceDimensions": [photo.metadata.width, photo.metadata.height],
                ]
                do {
                    let imported = try await library.files.decodedPhoto(photo, maximum: 720)
                    let digest = SHA256.hash(data: imported.data)
                    let renderer = PhotoRenderer(
                        source: imported.preview, directory: Bundle.main.resourceURL!,
                        data: imported.data, temperature: imported.rawTemperature,
                        previewMaximum: 720, resources: resources, sourceType: imported.sourceType)
                    var recipe = EditRecipe()
                    recipe.temperature = imported.rawTemperature
                    for flag in [
                        "film_render.grain.active", "film_render.halation.active",
                        "camera.diffusion_filter.active", "enlarger.diffusion_filter.active",
                    ] { recipe.flags[flag] = false }
                    recipe.mix = 0
                    let zero = try await renderer.render(recipe)
                    let neutral = try PhotoExporter.decodeSource(
                        imported.data, maximum: 720, sourceType: imported.sourceType)
                    guard zero.width == neutral.width && zero.height == neutral.height else {
                        throw PhotoExporter.Failure.render
                    }
                    let zeroError = zip(pixels(zero), pixels(neutral)).reduce(Float(0)) {
                        error, p in
                        max(error, abs(p.0.x - p.1.x), abs(p.0.y - p.1.y), abs(p.0.z - p.1.z))
                    }
                    item["mixZeroMaxError255"] = Double(zeroError * 255)
                    guard zeroError <= 2.0 / 255 else { throw PhotoExporter.Failure.render }
                    for mix in [0.01, 0.25, 0.5, 0.75, 0.99, 1.0] {
                        recipe.mix = mix
                        let frame = try await renderer.render(recipe)
                        guard
                            pixels(frame).allSatisfy({
                                $0.w > 0.99 && $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
                            })
                        else { throw PhotoExporter.Failure.render }
                    }
                    recipe.mix = 0
                    let exported = try await renderer.export(
                        recipe, size: .medium, format: .jpeg, quality: 0.95)
                    let target = folder.appendingPathComponent(photo.id.uuidString + ".jpg")
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: exported.0, to: target)
                    await renderer.discardExport()
                    item["exportDimensions"] = [exported.1, exported.2]
                    item["output"] = target.lastPathComponent
                    guard
                        SHA256.hash(data: try Data(contentsOf: library.files.sourceURL(photo)))
                            == digest
                    else { throw PhotoExporter.Failure.render }
                    item["result"] = "PASS"
                } catch {
                    item["result"] = "FAIL"
                    item["error"] = error.localizedDescription
                }
                cases.append(item)
            }
            await library.images.endExport()
            if let first = chosen.first {
                var clean = EditRecipe()
                clean.look.mode = .lut
                for flag in [
                    "film_render.grain.active", "film_render.halation.active",
                    "camera.diffusion_filter.active", "enlarger.diffusion_filter.active",
                ] { clean.flags[flag] = false }
                let items = chosen.prefix(2).map {
                    BatchExportItem(
                        id: $0.id, name: $0.filename,
                        source: library.files.sourceURL($0), recipe: clean)
                }
                let rejected = BatchExportItem(
                    id: UUID(), name: "Controlled memory rejection",
                    source: library.files.sourceURL(first), recipe: clean)
                let worker = BatchPhotoExporter(
                    directory: Bundle.main.resourceURL!, luts: library.luts.directory,
                    resources: resources)
                let model = BatchExportModel(items: [rejected] + items, library: library) {
                    item, size, format, quality in
                    if item.id == rejected.id {
                        try ImageMemoryAllowance.check(estimate: 101, allowance: 100)
                    }
                    return try await worker.export(
                        item, size: size, format: format, quality: quality)
                }
                model.start(size: .small, format: .jpeg, quality: 0.95, save: false)
                while model.running {
                    if Task.isCancelled {
                        model.cancel()
                        await Task.yield()
                    } else {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                report["batch"] = [
                    "ready": model.readyURLs.count, "failed": model.failureCount,
                    "expectedReady": items.count,
                    "result": model.readyURLs.count == items.count && model.failureCount == 1
                        ? "PASS" : "FAIL",
                ]
                model.cleanFiles()
            }
            sampler.cancel()
            let memory = await sampler.value
            report["minimumAvailableMB"] = memory.0 / 1_048_576
            report["peakAllocatedMetalMB"] = memory.1 / 1_048_576
            report["cases"] = cases
            report["finished"] = Date().ISO8601Format()
            report["result"] =
                !cases.isEmpty && cases.allSatisfy { $0["result"] as? String == "PASS" }
                    && (report["batch"] as? [String: Any])?["result"] as? String == "PASS"
                ? "PASS" : "FAIL"
            try? JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
            ).write(
                to: URL.cachesDirectory.appendingPathComponent("sdr-device-check.json"),
                options: .atomic)
            NSLog("SDR DEVICE CHECK %@", String(describing: report["result"]))
        }
        static func checkBypass(_ library: PhotoLibrary) async {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "--check-bypass"),
                index + 1 < arguments.count,
                let requested = UUID(uuidString: arguments[index + 1]),
                let photo = library.photo(requested)
            else { return }
            do {
                let imported = try await library.files.decodedPhoto(photo)
                var recipe = EditRecipe()
                recipe.look.mode = .lut
                let sdr = try SourceImageRenderer.prepare(
                    data: imported.data, fallback: imported.preview, recipe: recipe, maximum: 1080,
                    sourceType: imported.sourceType)
                recipe.look.mode = .spektrafilm
                let hdr = try SourceImageRenderer.prepare(
                    data: imported.data, fallback: imported.preview, recipe: recipe, maximum: 1080,
                    sourceType: imported.sourceType)
                let a = sdr.pixels.reduce(0.0) { $0 + Double($1.y) } / Double(sdr.pixels.count)
                let b = hdr.pixels.reduce(0.0) { $0 + Double($1.y) } / Double(hdr.pixels.count)
                let report = ["sdrMean": a, "hdrMean": b, "ratio": b / a]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(
                    to: URL.cachesDirectory.appendingPathComponent("bypass-check.json"),
                    options: .atomic)
                NSLog("BYPASS CHECK %@", report.description)
            } catch { NSLog("BYPASS CHECK failed %@", error.localizedDescription) }
        }
        static func run(_ library: PhotoLibrary) async {
            let arguments = ProcessInfo.processInfo.arguments
            let requestedID = arguments.firstIndex(of: "--check-photo").flatMap { index in
                index + 1 < arguments.count ? UUID(uuidString: arguments[index + 1]) : nil
            }
            guard arguments.contains("--check-export"),
                let photo = library.photos.first(where: {
                    $0.isRAW && (requestedID == nil || $0.id == requestedID)
                })
            else { return }
            var report: [String: String] = ["photo": photo.id.uuidString]
            let sampler = Task { () -> UInt64 in
                var minimum = UInt64(os_proc_available_memory())
                while !Task.isCancelled {
                    minimum = min(minimum, UInt64(os_proc_available_memory()))
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
                }
                return minimum
            }
            do {
                let imported = try await library.files.decodedPhoto(photo)
                let restored = try photo.recipeData.map {
                    try JSONDecoder().decode(EditRecipe.self, from: $0)
                }
                var recipe = restored ?? EditRecipe()
                recipe.temperature = imported.rawTemperature
                if ProcessInfo.processInfo.arguments.contains("--check-lut") {
                    recipe.look.mode = .lut
                    recipe.look.first.id = library.luts.items.first?.id
                }
                let renderer = PhotoRenderer(
                    source: imported.preview, directory: Bundle.main.resourceURL!,
                    data: imported.data,
                    temperature: imported.rawTemperature, lutDirectory: library.luts.directory,
                    sourceType: imported.sourceType)
                report["availableMB"] = String(os_proc_available_memory() / 1_048_576)
                let start = ProcessInfo.processInfo.systemUptime
                let result = try await renderer.export(
                    recipe, size: .full, format: .jpeg, quality: 1,
                    allowOvercommit: arguments.contains("--check-overcommit"))
                guard let encoded = CGImageSourceCreateWithURL(result.0 as CFURL, nil),
                    let checked = CGImageSourceCreateImageAtIndex(encoded, 0, nil),
                    checked.width == result.1, checked.height == result.2
                else {
                    throw PhotoExporter.Failure.encode
                }
                report["result"] = "PASS"
                report["dimensions"] = "\(result.1)x\(result.2)"
                report["seconds"] = String(ProcessInfo.processInfo.systemUptime - start)
                try? FileManager.default.removeItem(at: result.0)
            } catch {
                report["result"] = "FAIL"
                report["error"] = error.localizedDescription
            }
            sampler.cancel()
            report["minimumHeadroomMB"] = String(await sampler.value / 1_048_576)
            let url = URL.cachesDirectory.appendingPathComponent("export-check.json")
            try? JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
            ).write(
                to: url, options: .atomic)
            NSLog("EXPORT CHECK %@", report.description)
        }
    }
#endif
