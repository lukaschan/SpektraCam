import CoreGraphics
import Foundation

@main struct DarkroomChecks {
    static func main() throws {
        let sourceSize = CGSize(width: 600, height: 400)
        for paper in PrintLayout.Paper.allCases {
            for orientation in [PrintLayout.Orientation.automatic, .portrait, .landscape] {
                var layout = PrintLayout()
                layout.paper = paper
                layout.orientation = orientation
                layout.handSet = false  // a machine print is exactly centred
                layout.margin = 0
                let fit = PrintGeometry(imageSize: sourceSize, layout: layout, longEdge: 1200)!
                precondition(!fit.cropsImage)
                precondition(abs(fit.imageRect.midX - fit.paperSize.width / 2) < 1e-9)
                precondition(abs(fit.imageRect.width / fit.imageRect.height - 1.5) < 1e-9)
                layout.fill = true
                let fill = PrintGeometry(imageSize: sourceSize, layout: layout, longEdge: 1200)!
                precondition(fill.imageRect.width >= fill.paperSize.width - 0.01)
                precondition(fill.imageRect.height >= fill.paperSize.height - 0.01)
                precondition(fill.magnification == 0, "A borderless print showed blades")
                let restored = try JSONDecoder().decode(PrintLayout.self, from: JSONEncoder().encode(layout))
                precondition(restored == layout)
                // The border is the narrowest margin, a fraction of the sheet's long side.
                layout.fill = false; layout.margin = 0.05
                let bordered = PrintGeometry(imageSize: sourceSize, layout: layout, longEdge: 1200)!
                let long = max(bordered.paperSize.width, bordered.paperSize.height)
                precondition(bordered.paperSize == fit.paperSize, "The border moved or resized the sheet")
                let narrowest = min(bordered.imageRect.minX, bordered.imageRect.minY)
                precondition(abs(narrowest - 0.05 * long) < 1, "Border \(narrowest) px, expected \(0.05 * long)")
                // Hand-set easel: slightly off centre, never cropping, with a physical blade penumbra.
                layout.handSet = true
                for seed in [UInt32(1), 2, 3, 99] {
                    layout.easelSeed = seed
                    let centred = { var l = layout; l.handSet = false; return PrintGeometry(imageSize: sourceSize, layout: l, longEdge: 1200)! }()
                    let set = PrintGeometry(imageSize: sourceSize, layout: layout, longEdge: 1200)!
                    let dx = set.imageRect.minX - centred.imageRect.minX, dy = set.imageRect.minY - centred.imageRect.minY
                    precondition(!set.cropsImage && set.imageRect.size == centred.imageRect.size, "Hand-set easel cropped or resized")
                    precondition(abs(dx) <= 0.008 * long + 1e-9 && abs(dy) <= 0.008 * long + 1e-9, "Hand-set offset too large")
                    precondition(abs(dx) <= 0.45 * centred.imageRect.minX + 1e-9 && abs(dy) <= 0.45 * centred.imageRect.minY + 1e-9,
                                 "Hand-set offset ran into the margin")
                    // 0.05 mm paper spread plus h / (N(1 + M)): between 0.05 and 0.25 mm on paper.
                    let blurMillimetres = Double(set.bladeBlur) / (Double(long) / (paper.longMillimetres ?? 152.4))
                    precondition(set.magnification > 1 && blurMillimetres > 0.05 && blurMillimetres < 0.25, "Blade penumbra \(blurMillimetres) mm")
                }
            }
        }
        try checkBladeEdge()
        // Fill is the (negative) border at which the picture just covers the sheet.
        do {
            var sheet = PrintLayout(); sheet.paper = .fiveBySeven; sheet.handSet = false
            let fill = PrintGeometry.fillMargin(imageSize: sourceSize, layout: sheet)
            precondition(fill < 0 && PrintLayout.marginRange.contains(fill), "A 3:2 picture on 5 × 7 needs a negative fill border: \(fill)")
            sheet.margin = fill
            let covered = PrintGeometry(imageSize: sourceSize, layout: sheet, longEdge: 1400)!
            precondition(covered.imageRect.minX <= 0.5 && covered.imageRect.minY <= 0.5
                && covered.imageRect.maxX >= covered.paperSize.width - 0.5 && covered.imageRect.maxY >= covered.paperSize.height - 0.5,
                "The fill border did not cover the sheet: \(covered.imageRect) on \(covered.paperSize)")
            var square = PrintLayout(); square.paper = .fourBySix
            precondition(abs(PrintGeometry.fillMargin(imageSize: CGSize(width: 600, height: 400), layout: square)) < 1e-12,
                         "Matching proportions needed a fill border")
        }
        precondition(abs(Easel.penumbra(magnification: 4) - (4.5 / 40 + 0.05)) < 1e-12, "Easel penumbra formula")
        let legacyLayout = try JSONDecoder().decode(PrintLayout.self, from: Data("{\"paper\":\"fourBySix\",\"scale\":0.8}".utf8))
        precondition(!legacyLayout.handSet && legacyLayout.easelSeed == 1 && legacyLayout.blade == .natural,
                     "Saved layouts did not default to a machine-set natural easel")
        precondition(!PrintLayout().handSet, "The easel is hand-set by default")
        precondition(abs((legacyLayout.margin ?? 0) - 0.1) < 1e-9 && !legacyLayout.fill, "Image scale 80 % did not become a border")
        let legacyFill = try JSONDecoder().decode(PrintLayout.self, from: Data("{\"scale\":1.5}".utf8))
        precondition(legacyFill.fill, "An image scale past Fit did not become borderless")
        precondition(PrintLayout().resolvedMargin(.picture) == 0 && PrintLayout().isIdentity, "The default clean print gained a border")
        precondition(PrintLayout().resolvedMargin(.enlarger(frame: CGRect(x: 0, y: 0, width: 1, height: 1))) == PrintLayout.automaticMargin,
                     "A film-edge enlarger print lost its border")
        let legacy = try JSONDecoder().decode(EditRecipe.self, from: Data("{\"version\":4,\"filmID\":\"kodak_portra_400\",\"printID\":\"kodak_portra_endura\"}".utf8))
        precondition(legacy.printLayout == nil && legacy.filmID == "kodak_portra_400")
        var recipe = legacy
        var layout = PrintLayout()
        layout.paper = .eightByTen
        layout.margin = 0.2
        layout.handSet = false
        recipe.printLayout = layout
        precondition(recipe.processingRecipe == legacy.processingRecipe,
            "Paper layout invalidated the film processing cache")
        let roundTrip = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        precondition(roundTrip == recipe)
        try checkEdgeSelection()
        checkFixedGateCrops()
        for invalid in ["{\"scale\":0}", "{\"margin\":0.5}", "{\"margin\":-1}", "{\"paper\":\"future\"}"] {
            do {
                _ = try JSONDecoder().decode(PrintLayout.self, from: Data(invalid.utf8))
                preconditionFailure("Invalid layout was accepted")
            } catch is DecodingError {}
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 200, width: 600, height: 200))
        let source = context.makeImage()!
        let output = try PrintCompositor.render(source, layout: layout, maximum: 300)
        precondition(output.width == 300 && output.height == 240)
        precondition(output.bitsPerComponent == 8 && output.colorSpace?.name == CGColorSpace.sRGB)
        let expected = PrintGeometry(imageSize: sourceSize, layout: layout, longEdge: 300)!
        let bytes = pixels(output)
        let originalBytes = pixels(source)
        func rgb(_ data: [UInt8], _ width: Int, _ x: Int, _ y: Int) -> [UInt8] {
            Array(data[(y * width + x) * 4..<(y * width + x) * 4 + 3])
        }
        for point in [(0, 0), (299, 239), (150, 5), (5, 120)] {
            precondition(rgb(bytes, 300, point.0, point.1).allSatisfy { $0 == 255 },
                "The light table or its shadows leaked into the paper")
        }
        precondition(rgb(bytes, 300, 150, 100) == rgb(originalBytes, 600, 300, 100),
            "Composition inverted or changed the upper image")
        precondition(rgb(bytes, 300, 150, 140) == rgb(originalBytes, 600, 300, 300),
            "Composition inverted or changed the lower image")
        precondition(expected.imageRect.width == 180 && expected.imageRect.height == 120)
        // Placement is top-left in PrintGeometry and bottom-left in CoreGraphics: an off-centre
        // hand-set picture must land where the geometry says, and the blade softens only its edge.
        var handSet = layout; handSet.handSet = true; handSet.easelSeed = 3
        let placedGeometry = PrintGeometry(imageSize: sourceSize, layout: handSet, longEdge: 300)!
        let placed = pixels(try PrintCompositor.render(source, layout: handSet, maximum: 300))
        let r = placedGeometry.imageRect
        precondition(r.minY != expected.imageRect.minY, "Seed 3 did not move the picture vertically")
        let inside = rgb(placed, 300, Int(r.midX), Int(r.minY + r.height * 0.25))
        let outside = rgb(placed, 300, Int(r.midX), Int(r.minY) - 2)
        precondition(inside == rgb(originalBytes, 600, 300, 100) && outside.allSatisfy { $0 == 255 },
            "Hand-set placement drawn upside down or misplaced: \(inside), \(outside)")
        let full = try PrintCompositor.render(source, layout: layout)
        // Native: the 600 px picture at 0.3 × keeps its pixels, so the sheet is 1000 × 800.
        precondition(full.width == 1000 && full.height == 800, "Full output resampled the picture: \(full.width)×\(full.height)")
        var cropping = layout; cropping.fill = true
        let tight = try PrintCompositor.render(source, layout: cropping)
        precondition(max(tight.width, tight.height) == 500, "A sheet cropping the picture was enlarged: \(tight.width)×\(tight.height)")
        print("PASS: paper orientation, border/Fill, hand-set easel bounds/penumbra/placement, worn blade edges, legacy recipes, processing-cache independence, SDR composition, white margins, image orientation and native-resolution sheets")
    }
    /// The blade's edge carries the gate's wear profile: crisp but not ruled, rougher by kind,
    /// and the same mask for the same seed.
    static func checkBladeEdge() throws {
        func spread(_ kind: Easel.Kind) -> Double {
            let mask = Easel.mask(width: 3000, height: 2000, magnification: 4, kind: kind, seed: 7)!
            let data = mask.dataProvider!.data! as Data
            var crossings = [Double]()
            for y in stride(from: 300, to: 1700, by: 7) {
                let row = Array(data[(y * mask.bytesPerRow)..<(y * mask.bytesPerRow + 60)])
                guard let i = row.firstIndex(where: { $0 >= 128 }), i > 0 else { continue }
                let a = Double(row[i - 1]), b = Double(row[i])
                crossings.append(Double(i - 1) + (127.5 - a) / max(b - a, 1))
            }
            let mean = crossings.reduce(0, +) / Double(crossings.count)
            precondition(data[1000 * mask.bytesPerRow + 1500] == 255 && data[1000 * mask.bytesPerRow] < 40, "Blade mask interior or edge wrong")
            return (crossings.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(crossings.count)).squareRoot()
        }
        let precise = spread(.precise), natural = spread(.natural), worn = spread(.worn)
        // 3000 px per 36 mm: natural wear of 0.009 mm is under a pixel of wander along the blade.
        precondition(precise < natural && natural < worn && natural > 0.1 && natural < 3,
                     "Blade wear \(precise) / \(natural) / \(worn) px")
        let a = Easel.mask(width: 900, height: 600, magnification: 4, kind: .natural, seed: 3)!
        let b = Easel.mask(width: 900, height: 600, magnification: 4, kind: .natural, seed: 3)!
        precondition(a.dataProvider!.data! as Data == b.dataProvider!.data! as Data, "Blade mask not deterministic")
        print("Blade wander (px sd at 3000 px): precise \(precise), natural \(natural), worn \(worn)")
    }
    static func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
            count: image.width * image.height * 4))
    }

    static func checkEdgeSelection() throws {
        var recipe = EditRecipe()
        recipe.filmID = "fujifilm_c200"
        recipe.printID = "fujifilm_crystal_archive_typeii"
        precondition(recipe.filmEdgeSelection == nil && recipe.resolvedFilmEdgeType == .negativePrint)
        recipe.scanFilm = true
        precondition(recipe.resolvedFilmEdgeType == .negativeScan)
        recipe.filmID = "fujifilm_provia_100f"
        precondition(recipe.resolvedFilmEdgeType == .reversalScan)
        recipe.scanFilm = false
        recipe.printID = "kodak_2383"
        precondition(recipe.resolvedFilmEdgeType == .cinemaPrint)
        recipe.printID = "kodak_2393"
        precondition(recipe.resolvedFilmEdgeType == .cinemaPrint)
        recipe.look.mode = .lut
        precondition(recipe.resolvedFilmEdgeType == .negativePrint)

        var selection = FilmEdgeSelection()
        selection.mode = .manual
        // Every manual family remains available in every film/print/scan and B&W combination.
        for type in FilmEdgeType.allCases {
            selection.manualType = type
            for mode in EditRecipe.LookMode.allCases {
                recipe.look.mode = mode
                for film in FilmStock.films {
                    for print in FilmStock.prints {
                        for directScan in [false, true] {
                            for monochrome in [false, true] {
                                recipe.filmID = film.id
                                recipe.printID = print.id
                                recipe.scanFilm = directScan
                                recipe.tone.monochrome = monochrome
                                recipe.filmEdgeSelection = selection
                                precondition(recipe.resolvedFilmEdgeType == type,
                                    "Develop or B&W restricted the user's manual edge choice")
                            }
                        }
                    }
                }
            }
        }
        recipe.look.mode = .spektrafilm
        recipe.filmID = "fujifilm_c200"
        recipe.printID = "fujifilm_crystal_archive_typeii"
        recipe.scanFilm = false
        recipe.tone.monochrome = false
        selection.manualType = .reversalScan
        selection.mode = .automatic
        recipe.filmEdgeSelection = selection
        precondition(recipe.resolvedFilmEdgeType == .negativePrint)
        recipe.tone.monochrome = true
        precondition(recipe.resolvedFilmEdgeType == .negativePrint,
            "Monochrome output changed the edge family")
        let restored = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        precondition(restored.filmEdgeSelection?.manualType == .reversalScan)
        var manualAgain = restored
        manualAgain.filmEdgeSelection?.mode = .manual
        precondition(manualAgain.resolvedFilmEdgeType == .reversalScan)
        precondition(manualAgain.processingRecipe == recipe.processingRecipe,
            "An inactive edge preference changed film processing")
        let legacy = try JSONDecoder().decode(EditRecipe.self, from: Data("{\"version\":5}".utf8))
        precondition(legacy.filmEdgeSelection == nil && legacy.resolvedFilmEdgeType == .negativePrint)
        let legacyData = try JSONEncoder().encode(legacy)
        let object = try JSONSerialization.jsonObject(with: legacyData) as! [String: Any]
        precondition(object["filmEdgeSelection"] == nil,
            "An untouched recipe acquired edge-selection data")
        print("PASS: Develop-based Auto, unrestricted manual families, retained manual choice, B&W independence and saved/legacy edge preferences")
    }
    static func checkFixedGateCrops() {
        for format in FilmEdgeLayout.Format.allCases {
            var layout = FilmEdgeLayout(); layout.format = format
            for size in [CGSize(width: 1200, height: 800), CGSize(width: 800, height: 1200),
                         CGSize(width: 1200, height: 1200), CGSize(width: 1800, height: 600)] {
                var previous = CropSelection()
                previous.normalizedRect = CGRect(x: 0.12, y: 0.18, width: 0.7, height: 0.62)
                let result = layout.constrainedCrop(previous, imageSize: size)
                let rect = result.normalizedRect
                precondition(previous.normalizedRect.contains(rect))
                precondition(abs(rect.midX - previous.normalizedRect.midX) < 1e-9)
                precondition(abs(rect.midY - previous.normalizedRect.midY) < 1e-9)
                precondition(layout.constrainedCrop(result, imageSize: size) == result, "Repeated framing accumulated zoom")
                let geometry = FilmEdgeGeometry(imageSize: result.pixelRect(in: size).size, layout: layout, longEdge: 1200)!
                let longMM = max(geometry.gate.width, geometry.gate.height) * geometry.millimetersPerPixel
                precondition(abs(longMM - layout.gateSize.width) < 1e-9)
                var changed = result
                changed.orientation = .portrait
                changed.setAspect(layout.cropAspect, imageAspect: size.width / size.height)
                let portrait = layout.constrainedCrop(changed, imageSize: size)
                precondition(layout.matchesGate(portrait.pixelRect(in: size).size))
            }
        }
        var recipe = EditRecipe(); recipe.filmEdgeLayout = FilmEdgeLayout()
        let develop = recipe.processingRecipe
        recipe.constrainFilmEdgeCrop(imageSize: CGSize(width: 800, height: 800))
        precondition(recipe.crop.normalizedRect.width == 1 && abs(recipe.crop.normalizedRect.height - 2 / 3) < 1e-9)
        precondition(recipe.processingRecipe == develop)
        print("PASS: fixed physical gate, bounded centered trim, idempotence, portrait, 120 and unchanged Develop settings")
    }
}
