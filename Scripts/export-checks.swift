import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct ExportChecks {
    static func main() throws {
        func image(_ width: Int, _ height: Int) -> CGImage {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
            return context.makeImage()!
        }
        func encode(_ bitmap: CGImage, orientation: Int) -> Data {
            let bytes = NSMutableData()
            let destination = CGImageDestinationCreateWithData(bytes, UTType.tiff.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, bitmap, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            precondition(CGImageDestinationFinalize(destination))
            return bytes as Data
        }
        let source = image(200, 120)
        for orientation in 1...8 {
            let data = encode(source, orientation: orientation), original = data
            let result = try PhotoExporter.renderOriginal(data, crop: CropSelection(), geometry: ImageGeometry())
            precondition(result.width == (orientation >= 5 ? 120 : 200))
            precondition(result.height == (orientation >= 5 ? 200 : 120))
            let expected = CIImage(cgImage: source).oriented(forExifOrientation: Int32(orientation))
            let context = CIContext(options: [.workingColorSpace: NSNull()])
            let golden = context.createCGImage(expected, from: expected.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
            func pixels(_ cg: CGImage) -> [UInt8] {
                let c = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: cg.width * cg.height * 4))
            }
            precondition(pixels(result) == pixels(golden), "EXIF orientation mismatch: \(orientation)")
            precondition(data == original)
        }
        let large = encode(image(3072, 2048), orientation: 1)
        let imported = ImportedPhoto.decode(large, maximum: 1080)!
        precondition(imported.preview.width == 1080 && imported.preview.height == 720)
        precondition(imported.width == 3072 && imported.height == 2048 && imported.data == large)
        var crop = CropSelection(); crop.setAspect(.square, imageAspect: 1.5)
        let full = try PhotoExporter.renderOriginal(large, crop: CropSelection(), geometry: ImageGeometry())
        precondition(full.width == 3072 && full.height == 2048, "Preview-sized export")
        let square = try PhotoExporter.renderOriginal(large, crop: crop, geometry: ImageGeometry())
        precondition(square.width == 2048 && square.height == 2048)
        let directory = FileManager.default.temporaryDirectory.appending(path: "Spektrafilm-Test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        for format in PhotoExporter.Format.allCases {
            let url = try PhotoExporter.write(square, format: format, directory: directory)
            let encoded = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let decoded = CGImageSourceCreateImageAtIndex(encoded, 0, nil)!
            precondition(decoded.width == 2048 && decoded.height == 2048)
            precondition(decoded.colorSpace?.model == .rgb)
        }
        print("PASS: eight EXIF orientations, 1080px preview, source preservation, full-resolution crop, JPEG/PNG round-trips")
    }
}
