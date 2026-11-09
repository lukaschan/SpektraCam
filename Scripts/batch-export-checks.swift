import CoreGraphics
import Foundation
import ImageIO

@main struct BatchChecks {
    @MainActor static func main() async throws {
        let project = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(
            fileURLWithPath: "/private/tmp/spektrafilm-build/BatchChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let source = root.appendingPathComponent("source.png")
        let destination = CGImageDestinationCreateWithURL(
            source as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let library = try PhotoLibrary(
            root: root.appendingPathComponent("Library"),
            cache: root.appendingPathComponent("Cache"),
            modelDirectory: project.appendingPathComponent("SpektraCam/Resources/ModelData"))
        let bad = BatchExportItem(id: UUID(), name: "Oversized", source: source, recipe: nil)
        let good = BatchExportItem(id: UUID(), name: "Source", source: source, recipe: nil)
        let worker = BatchPhotoExporter(
            directory: project.appendingPathComponent("SpektraCam/Resources/ModelData"),
            luts: library.luts.directory, resources: library.images.resources)
        let model = BatchExportModel(items: [bad, good], library: library) {
            item, size, format, quality in
            if item.id == bad.id { try ImageMemoryAllowance.check(estimate: 101, allowance: 100) }
            return try await worker.export(item, size: size, format: format, quality: quality)
        }
        model.start(size: .full, format: .png, quality: 1, save: false)
        while model.running { try await Task.sleep(for: .milliseconds(20)) }
        precondition(model.failureCount == 1 && model.readyURLs.count == 1)
        precondition(model.completedCount == 2 && model.remainingCount == 1)
        let completed = model.readyURLs
        model.start(size: .full, format: .png, quality: 1, save: false)
        while model.running { try await Task.sleep(for: .milliseconds(20)) }
        precondition(model.readyURLs == completed, "Retry exported the completed photo again")
        precondition(completed.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        model.start(size: .full, format: .png, quality: 1, save: false)
        model.memoryWarning()
        while model.running { try await Task.sleep(for: .milliseconds(20)) }
        precondition(model.stopReason != nil && model.readyURLs == completed)
        model.cleanFiles()
        precondition(completed.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        print(
            "PASS: controlled memory rejection, next-item success, retry skips completed items, low-memory cancellation and temporary-file cleanup"
        )
    }
}
