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
                let fit = PrintGeometry(imageSize: sourceSize, layout: layout, longEdge: 1200)!
                precondition(!fit.cropsImage)
                precondition(abs(fit.imageRect.midX - fit.paperSize.width / 2) < 1e-9)
                precondition(abs(fit.imageRect.width / fit.imageRect.height - 1.5) < 1e-9)
                layout.scale = fit.fillScale
                let fill = PrintGeometry(imageSize: sourceSize, layout: layout, longEdge: 1200)!
                precondition(fill.imageRect.width >= fill.paperSize.width - 0.01)
                precondition(fill.imageRect.height >= fill.paperSize.height - 0.01)
                let restored = try JSONDecoder().decode(PrintLayout.self, from: JSONEncoder().encode(layout))
                precondition(restored == layout)
                // Hand-set easel: slightly off centre, never cropping, with a physical blade penumbra.
                layout.scale = 0.8; layout.handSet = true
                for seed in [UInt32(1), 2, 3, 99] {
                    layout.easelSeed = seed
                    let centred = { var l = layout; l.handSet = false; return PrintGeometry(imageSize: sourceSize, layout: l, longEdge: 1200)! }()
                    let set = PrintGeometry(imageSize: sourceSize, layout: layout, longEdge: 1200)!
                    let long = max(set.paperSize.width, set.paperSize.height)
                    let dx = set.imageRect.minX - centred.imageRect.minX, dy = set.imageRect.minY - centred.imageRect.minY
                    precondition(!set.cropsImage && set.imageRect.size == centred.imageRect.size, "Hand-set easel cropped or resized")
                    precondition(abs(dx) <= 0.008 * long + 1e-9 && abs(dy) <= 0.008 * long + 1e-9, "Hand-set offset too large")
                    precondition(abs(dx) <= 0.45 * centred.imageRect.minX + 1e-9 && abs(dy) <= 0.45 * centred.imageRect.minY + 1e-9,
                                 "Hand-set offset ran into the margin")
                    if let sheet = paper.longMillimetres {
                        // 0.03 mm paper spread plus h / (N(1 + M)): between 0.05 and 0.2 mm on paper.
                        let blurMillimetres = Double(set.bladeBlur) / (Double(long) / sheet)
                        precondition(blurMillimetres > 0.05 && blurMillimetres < 0.2, "Blade penumbra \(blurMillimetres) mm")
                    } else {
                        precondition(dx == 0 && dy == 0 && set.bladeBlur == 0, "As-image paper moved with the easel")
                    }
                }
            }
        }
        precondition(abs(Easel.penumbra(magnification: 4) - (3.0 / 40 + 0.03)) < 1e-12, "Easel penumbra formula")
        let legacyLayout = try JSONDecoder().decode(PrintLayout.self, from: Data("{\"paper\":\"fourBySix\",\"scale\":0.8}".utf8))
        precondition(legacyLayout.handSet && legacyLayout.easelSeed == 1, "Saved layouts did not default to a hand-set easel")
        let legacy = try JSONDecoder().decode(EditRecipe.self, from: Data("{\"version\":4,\"filmID\":\"kodak_portra_400\",\"printID\":\"kodak_portra_endura\"}".utf8))
        precondition(legacy.printLayout == nil && legacy.filmID == "kodak_portra_400")
        var recipe = legacy
        var layout = PrintLayout()
        layout.paper = .eightByTen
        layout.scale = 0.5
        layout.handSet = false
        recipe.printLayout = layout
        precondition(recipe.processingRecipe == legacy.processingRecipe,
            "Paper layout invalidated the film processing cache")
        let roundTrip = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        precondition(roundTrip == recipe)
        try checkEdgeSelection()
        checkFixedGateCrops()
        for invalid in ["{\"scale\":0}", "{\"scale\":5}", "{\"paper\":\"future\"}"] {
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
        precondition(expected.imageRect.width == 150 && expected.imageRect.height == 100)
        // Placement is top-left in PrintGeometry and bottom-left in CoreGraphics: an off-centre
        // hand-set picture must land where the geometry says, and the blade softens only its edge.
        var handSet = layout; handSet.handSet = true; handSet.easelSeed = 3
        let placedGeometry = PrintGeometry(imageSize: sourceSize, layout: handSet, longEdge: 300)!
        let placed = pixels(try PrintCompositor.render(source, layout: handSet, maximum: 300, bladeEdge: true))
        let r = placedGeometry.imageRect
        precondition(r.minY != expected.imageRect.minY, "Seed 3 did not move the picture vertically")
        let inside = rgb(placed, 300, Int(r.midX), Int(r.minY + r.height * 0.25))
        let outside = rgb(placed, 300, Int(r.midX), Int(r.minY) - 2)
        precondition(inside == rgb(originalBytes, 600, 300, 100) && outside.allSatisfy { $0 == 255 },
            "Hand-set placement drawn upside down or misplaced: \(inside), \(outside)")
        let full = try PrintCompositor.render(source, layout: layout)
        // Native: the 600 px picture at half scale keeps its pixels, so the sheet is 1200 × 960.
        precondition(full.width == 1200 && full.height == 960, "Full output resampled the picture: \(full.width)×\(full.height)")
        var cropping = layout; cropping.scale = 2
        let tight = try PrintCompositor.render(source, layout: cropping)
        precondition(max(tight.width, tight.height) == 300, "A sheet cropping the picture was enlarged: \(tight.width)×\(tight.height)")
        print("PASS: paper orientation, Fit/Fill, centered scale, hand-set easel bounds/penumbra/placement, legacy recipes, processing-cache independence, SDR composition, white margins, image orientation and native-resolution sheets")
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
