#if DEBUG && targetEnvironment(simulator)
import UIKit

/// A card's code must read back as the formula it was made from, through the detector that
/// reads a saved card, at the sizes and compression a shared picture ends up with. Runs only
/// in the isolated UI-test library; the cards and a report are written to a host folder.
@MainActor enum FormulaCardChecks {
    static func run(_ library: PhotoLibrary) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-test-library"), let option = args.firstIndex(of: "--check-formula-card"),
            option + 1 < args.count
        else { return }
        let folder = URL(fileURLWithPath: args[option + 1])
        var report: [String: Any] = [:]
        do {
            try await check(library, folder: folder, report: &report)
            report["result"] = "PASS"
        } catch {
            report["result"] = "FAIL"
            report["error"] = String(describing: error)
        }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("report.json"), options: .atomic)
    }
    private struct Failed: Error, CustomStringConvertible { let description: String }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failed(description: message) }
    }
    private static func scaled(_ image: UIImage, width: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: (width * image.size.height / image.size.width).rounded())
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    private static func check(_ library: PhotoLibrary, folder: URL, report: inout [String: Any]) async throws {
        var look = EditRecipe()
        look.filmID = "fujifilm_c200"
        look.printID = "fujifilm_crystal_archive_typeii"
        look.tone.contrast = 1.15
        look.tone.exposureEV = 0.5
        look.source.warmth = 12
        look.flags["film_render.grain.active"] = false
        look.numbers["enlarger.y_filter_shift"] = 7
        look.numbers["film_render.halation.halation_amount"] = 0.5
        look.removeDefaultOverrides()
        var bordered = look
        bordered.printLayout = PrintLayout.enlargerDefault
        bordered.filmEdgeLayout = FilmEdgeLayout.newDefault()
        let formulae = [
            try Formula(name: "Tungsten night", note: "f/8 · 1/60, corner shop", parts: [.look, .exposure], from: look, luts: []),
            try Formula(name: "Contact strip", parts: [.look, .darkroom], from: bordered, luts: []),
        ]
        var links: [String: String] = [:]
        var sizes: [String: Any] = [:]
        for formula in formulae {
            try await library.formulae.save(formula)
            let stored = try Data(contentsOf: library.formulae.fileURL(formula.id))
            let link = try FormulaLink.url(for: stored).absoluteString
            links[formula.name] = link
            let code = FormulaCode(link)
            try require(code != nil, formula.name + ": the link does not fit a code")
            var picture: UIImage?
            if let photo = library.photos.first, let preview = library.preview(photo, applying: formula) {
                picture = UIImage(cgImage: try await library.images.image(preview, thumbnail: false))
            }
            for (suffix, photo) in [("", nil), ("-photo", picture)] where suffix.isEmpty || photo != nil {
                let card = FormulaCard(
                    name: formula.name, note: formula.note, process: FormulaProcess(formula, luts: library.luts),
                    code: code, photo: photo)
                guard let image = card.image(), let png = image.pngData() else {
                    throw Failed(description: formula.name + ": the card did not render")
                }
                try require(
                    image.size.width * image.scale == 1080 && image.size.height * image.scale == 1350,
                    "The card is not 1080 × 1350")
                try png.write(to: folder.appendingPathComponent(formula.name + suffix + ".png"), options: .atomic)
                // The saved picture, through the same reader an import uses.
                let read = try Formula(data: FormulaCode.file(inImage: png))
                try require(read == library.formulae.formula(formula.id), formula.name + ": the code read back another formula")
                try require(
                    await library.formulae.arrival(of: FormulaCode.file(inImage: png)) == .same,
                    formula.name + ": its own card was not recognised")
                // Shared pictures are shrunk and recompressed.
                var reads: [String] = []
                for width in [720.0, 540.0, 432.0] {
                    if let small = scaled(image, width: width), FormulaCode.read(small).contains(link) {
                        reads.append("\(Int(width)) px")
                    }
                }
                if let jpeg = image.jpegData(compressionQuality: 0.5), (try? FormulaCode.file(inImage: jpeg)) == stored.linked {
                    reads.append("JPEG 50 %")
                }
                try require(reads.contains("720 px") && reads.contains("JPEG 50 %"), formula.name + suffix + ": only read at " + reads.joined(separator: ", "))
                sizes[formula.name + suffix] = [
                    "modules": code!.side, "characters": link.utf8.count, "alsoReadAt": reads,
                    "pixelsPerModule": FormulaCodeView.pitch(code!, side: FormulaCard.codeSide, pixelScale: FormulaCard.exportScale)
                        * FormulaCard.exportScale,
                ]
            }
        }
        report["links"] = links
        report["cards"] = sizes
    }
}
private extension Data {
    /// This file as a link would deliver it.
    var linked: Data? { (try? FormulaLink.url(for: self)).flatMap { try? FormulaLink.file(from: $0.absoluteString) } }
}
#endif
