import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO

@main struct SDRChecks {
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [
        .workingColorSpace: linear, .workingFormat: CIFormat.RGBAf,
    ])
    static func pixels(_ image: CGImage) -> [SIMD4<Float>] {
        var result = [SIMD4<Float>](repeating: .zero, count: image.width * image.height)
        result.withUnsafeMutableBytes {
            context.render(
                CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: image.width * 16,
                bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                format: .RGBAf,
                colorSpace: srgb)
        }
        precondition(
            result.allSatisfy { $0.w > 0.99 && $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        return result
    }
    static func maxError(_ a: CGImage, _ b: CGImage) -> Float {
        precondition(a.width == b.width && a.height == b.height)
        return zip(pixels(a), pixels(b)).reduce(Float(0)) { e, pair in
            max(e, abs(pair.0.x - pair.1.x), abs(pair.0.y - pair.1.y), abs(pair.0.z - pair.1.z))
        }
    }
    static func main() async throws {
        // ProRAW's EXIF timezone can be present in TIFF yet absent from ImageIO's properties.
        for little in [false, true] {
            var tiff = Data(repeating: 0, count: 51)
            func put(_ offset: Int, _ value: Int, _ count: Int) {
                for index in 0..<count {
                    let shift = (little ? index : count - 1 - index) * 8
                    tiff[offset + index] = UInt8((value >> shift) & 255)
                }
            }
            tiff[0] = little ? 0x49 : 0x4d; tiff[1] = tiff[0]
            put(2, 42, 2); put(4, 8, 4); put(8, 1, 2)
            put(10, 34665, 2); put(12, 4, 2); put(14, 1, 4); put(18, 26, 4)
            put(26, 1, 2); put(28, 36881, 2); put(30, 2, 2)
            put(32, 7, 4); put(36, 44, 4)
            tiff.replaceSubrange(44..<51, with: Array("-05:00\0".utf8))
            precondition(PhotoSource.tiffTimeOffsets(tiff)[kCGImagePropertyExifOffsetTimeOriginal] == "-05:00")
            precondition(PhotoSource.tiffTimeOffsets(tiff.prefix(45)).isEmpty)
            put(36, 0xffff_ffff, 4)
            precondition(PhotoSource.tiffTimeOffsets(tiff).isEmpty)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = root.appendingPathComponent("SpektraCam/Resources/ModelData")
        let folder = URL(
            fileURLWithPath: "/private/tmp/spektrafilm-build/SDRChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = CGContext(
            data: nil, width: 96, height: 64, bitsPerComponent: 8,
            bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(colorSpace: srgb, components: [0.3, 0.5, 0.7, 1])!)
        bitmap.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        let source = bitmap.makeImage()!
        let input = folder.appendingPathComponent("capture.png")
        let dest = CGImageDestinationCreateWithURL(
            input as CFURL, "public.png" as CFString, 1, nil)!
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 33.5, kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 151.2, kCGImagePropertyGPSLongitudeRef: "W",
            kCGImagePropertyGPSAltitude: 12.5, kCGImagePropertyGPSAltitudeRef: 0,
            kCGImagePropertyGPSDateStamp: "2026:11:04", kCGImagePropertyGPSTimeStamp: "12:34:56",
        ]
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2026:11:04 12:34:56",
            kCGImagePropertyExifOffsetTimeOriginal: "+00:00",
        ]
        CGImageDestinationAddImage(
            dest, source,
            [
                kCGImagePropertyGPSDictionary: gps,
                kCGImagePropertyExifDictionary: exif,
            ] as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        let data = try Data(contentsOf: input)
        for format in PhotoExporter.Format.allCases {
            let output = try PhotoExporter.write(
                source, format: format, directory: folder, sourceData: data)
            let imageSource = CGImageSourceCreateWithURL(output as CFURL, nil)!
            let p = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)! as NSDictionary
            let readGPS = p[kCGImagePropertyGPSDictionary] as! NSDictionary
            precondition(readGPS[kCGImagePropertyGPSLatitudeRef] as? String == "S")
            precondition(readGPS[kCGImagePropertyGPSLongitudeRef] as? String == "W")
            precondition(abs((readGPS[kCGImagePropertyGPSAltitude] as! Double) - 12.5) < 0.01)
            precondition(readGPS[kCGImagePropertyGPSDateStamp] as? String == "2026:11:04")
            let readExif = p[kCGImagePropertyExifDictionary] as! [CFString: Any]
            precondition(
                readExif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:11:04 12:34:56")
            precondition(readExif[kCGImagePropertyExifOffsetTimeOriginal] as? String == "+00:00")
            precondition(p[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
            let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
            precondition(image.width == 96 && image.height == 64 && image.bitsPerComponent == 8)
            precondition(image.colorSpace?.name == CGColorSpace.sRGB)
            print(
                "PASS:", format.rawValue,
                "GPS hemispheres, altitude, UTC, capture date, dimensions and SDR profile")
        }
        do {
            try ImageMemoryAllowance.check(estimate: 101, allowance: 100)
            preconditionFailure("Admission accepted insufficient memory")
        } catch is ImageMemoryAllowance.Failure {}
        try ImageMemoryAllowance.check(estimate: 99, allowance: 100)

        var hdrPixels = [SIMD4<Float>](repeating: .init(0.18, 0.18, 0.18, 1), count: 96 * 64)
        for y in 8..<56 { for x in 48..<88 { hdrPixels[y * 96 + x] = .init(4, 2, 1.2, 1) } }
        let hdr = CIImage(
            bitmapData: hdrPixels.withUnsafeBytes { Data($0) }, bytesPerRow: 96 * 16,
            size: CGSize(width: 96, height: 64), format: .RGBAf, colorSpace: linear)
        let iso = folder.appendingPathComponent("iso-hdr.heic")
        try context.writeHEIF10Representation(
            of: hdr, to: iso,
            colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!, options: [:])
        let gain = folder.appendingPathComponent("gain-hdr.heic")
        let sdr = hdr.applyingFilter(
            "CIToneMapHeadroom", parameters: ["inputSourceHeadroom": 4, "inputTargetHeadroom": 1])
        try context.writeHEIFRepresentation(
            of: sdr, to: gain, format: .RGBA8, colorSpace: srgb,
            options: [.hdrImage: hdr])

        let resources = FilmRenderResources(directory: directory)
        let worker = BatchPhotoExporter(directory: directory, luts: folder, resources: resources)
        let invalid = BatchExportItem(
            id: UUID(), name: "missing", source: folder.appendingPathComponent("missing.png"),
            recipe: nil
        )
        do {
            _ = try await worker.export(invalid, size: .small, format: .png, quality: 1)
            preconditionFailure("Missing input succeeded")
        } catch {}
        let item = BatchExportItem(id: UUID(), name: "capture", source: input, recipe: nil)
        let url = try await worker.export(item, size: .small, format: .png, quality: 1)
        precondition(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.removeItem(at: url)
        print("PASS: deterministic memory admission, failed-item isolation and next-item export")

        for file in [input, iso, gain]
            + CommandLine.arguments.dropFirst(2).map({ URL(fileURLWithPath: $0) })
        {
            let bytes = try Data(contentsOf: file)
            let digest = SHA256.hash(data: bytes)
            let type = PhotoSource.typeHint(for: file)
            guard let photo = ImportedPhoto.decode(bytes, maximum: 192, typeHint: type) else {
                preconditionFailure("Decode failed: \(file)")
            }
            let renderer = PhotoRenderer(
                source: photo.preview, directory: directory, data: bytes,
                temperature: photo.rawTemperature, previewMaximum: 192, resources: resources,
                sourceType: photo.sourceType)
            var recipe = EditRecipe()
            recipe.temperature = photo.rawTemperature
            for key in [
                "film_render.grain.active", "film_render.halation.active",
                "camera.diffusion_filter.active", "enlarger.diffusion_filter.active",
            ] { recipe.flags[key] = false }
            recipe.mix = 0
            let zero = try await renderer.render(recipe)
            let neutral = try PhotoExporter.decodeSource(
                bytes, maximum: 192, sourceType: photo.sourceType)
            let zeroError = maxError(zero, neutral)
            print(
                "Mix zero control", file.lastPathComponent, zeroError,
                "center", pixels(zero)[32 * zero.width + 72],
                pixels(neutral)[32 * neutral.width + 72])
            precondition(zeroError < 1.5 / 255, "Mix zero differs from neutral SDR development")
            for mix in [0.01, 0.25, 0.5, 0.75, 0.99, 1.0] {
                recipe.mix = mix
                let actual = try await renderer.render(recipe)
                _ = pixels(actual)
            }
            recipe.mix = 0
            let restored = try await renderer.render(recipe)
            precondition(maxError(zero, restored) == 0, "Mix cache changed zero endpoint")
            let out = try await renderer.export(recipe, size: .small, format: .png, quality: 1)
            let outputSource = CGImageSourceCreateWithURL(out.0 as CFURL, nil)!
            let outputProperties = PhotoSource.captureProperties(
                outputSource, data: try Data(contentsOf: out.0))
            let outputExif = outputProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            for (key, value) in PhotoSource.tiffTimeOffsets(bytes) {
                precondition(outputExif?[key] as? String == value, "Lost source capture timezone")
            }
            try FileManager.default.removeItem(at: out.0)
            await renderer.discardExport()
            let after = try Data(contentsOf: file)
            precondition(SHA256.hash(data: after) == digest)
            print(
                "PASS:", file.lastPathComponent, photo.width, photo.height,
                "typed import, Mix 0–100%, reset, SDR export, unchanged original")
        }
        if let controlRoot = ProcessInfo.processInfo.environment["SPEKTRACAM_LUT_CONTROL_ROOT"] {
            let control = URL(fileURLWithPath: controlRoot)
            let inputURL = control.appendingPathComponent(
                "photoshop_validation/01_input_diagnostic_sRGB16_ICC.png")
            let expectedURL = control.appendingPathComponent(
                "photoshop_validation/07_Photoshop_LUT33_sRGB16_result.png")
            let cubeURL = control.appendingPathComponent(
                "recovered/chromagraph_1517_1518_experimental/luts/Chroma_synthetic_sRGB_EXPERIMENTAL_33.cube"
            )
            let cubeData = try Data(contentsOf: cubeURL)
            let cube = try CubeLUT(data: cubeData, filename: cubeURL.lastPathComponent)
            try cubeData.write(to: folder.appendingPathComponent(cube.id + ".cube"))
            let bytes = try Data(contentsOf: inputURL)
            let photo = ImportedPhoto.decode(bytes, maximum: 2048)!
            let renderer = PhotoRenderer(
                source: photo.preview, directory: directory, data: bytes,
                lutDirectory: folder, previewMaximum: 2048, resources: resources,
                sourceType: photo.sourceType)
            var recipe = EditRecipe()
            recipe.look.mode = .lut
            recipe.look.first = .init(id: cube.id, mix: 1)
            for key in [
                "film_render.grain.active", "film_render.halation.active",
                "camera.diffusion_filter.active", "enlarger.diffusion_filter.active",
            ] { recipe.flags[key] = false }
            let actual = try await renderer.render(recipe)
            let expectedSource = CGImageSourceCreateWithURL(expectedURL as CFURL, nil)!
            let expected = CGImageSourceCreateImageAtIndex(expectedSource, 0, nil)!
            let error = maxError(actual, expected)
            precondition(
                error <= 1.0 / 255, "App photo-LUT path diverged from the Photoshop reference")
            print(
                "PASS: actual 33-cube Photoshop control; maximum encoded-channel error",
                error * 255, "/ 255")
        }
    }
}
