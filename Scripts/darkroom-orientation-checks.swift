import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct OrientationChecks {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let resources = FilmRenderResources(directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"))
        let context = CGContext(data: nil, width: 480, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.04, green: 0.08, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 360))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 192, y: 132, width: 96, height: 96))
        let bitmap = context.makeImage()!
        var count = 0
        for type in [UTType.tiff, .jpeg, .heic] {
            for value in 1...8 {
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, bitmap, [kCGImagePropertyOrientation: value, kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
                precondition(CGImageDestinationFinalize(destination))
                let bytes = data as Data
                let photo = ImportedPhoto.decode(bytes)!
                let native = CIImage(data: bytes, options: [.applyOrientationProperty: true])!.extent.size
                precondition(photo.width == Int(native.width) && photo.height == Int(native.height),
                    "\(type.identifier) EXIF \(value): stored dimensions did not match upright decoded pixels")
                precondition(photo.preview.width == photo.width && photo.preview.height == photo.height)
                var recipe = EditRecipe()
                recipe.look.enabled = false
                recipe.flags["film_render.grain.active"] = false
                recipe.flags["film_render.halation.active"] = false
                recipe.filmEdgeLayout = FilmEdgeLayout()
                recipe.constrainFilmEdgeCrop(imageSize: native)
                let crop = recipe.crop.pixelRect(in: native)
                let portrait = native.height > native.width
                precondition((crop.height > crop.width) == portrait)
                // A circle stays circular in cropped scene pixels. This catches the actual
                // portrait→landscape squeeze, rather than merely checking an orientation label.
                let framed = try SourceImageRenderer.prepare(data: bytes, fallback: photo.preview, recipe: recipe,
                    maximum: 480, framing: recipe)
                var minX = framed.width, minY = framed.height, maxX = 0, maxY = 0
                for y in 0..<framed.height { for x in 0..<framed.width {
                    let p = framed.pixels[y * framed.width + x]
                    if min(p.x, min(p.y, p.z)) > 0.8 {
                        minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                }}
                precondition(abs((maxX - minX) - (maxY - minY)) <= 2, "Source circle became an ellipse")
                let renderer = PhotoRenderer(source: photo.preview, directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"),
                    data: bytes, resources: resources, sourceType: photo.sourceType, description: photo.sourceDescription)
                let preview = try await renderer.renderFilmEdge(recipe, maximum: 160)
                precondition((preview.height > preview.width) == portrait)
                var paper = PrintLayout(); paper.paper = .fourBySix
                recipe.printLayout = paper
                let automatic = try await renderer.renderPresentation(recipe, maximum: 160)
                precondition((automatic.height > automatic.width) == portrait, "Default paper ignored the cropped result")
                paper.orientation = portrait ? .landscape : .portrait
                recipe.printLayout = paper
                let rotated = try await renderer.renderPresentation(recipe, maximum: 160)
                precondition((rotated.height > rotated.width) != portrait, "Explicit paper orientation was overwritten")
                precondition(photo.data == bytes)
                count += 1
            }
        }
        precondition(count >= 16)
        print("PASS: \(count) TIFF/JPEG/HEIC × EXIF 1–8 cases; upright metadata, portrait crop, no circle distortion, matching default paper, explicit paper override and original-byte preservation")
    }
}
