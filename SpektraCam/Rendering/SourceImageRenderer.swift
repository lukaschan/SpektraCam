import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// App-level input controls precede the pinned photographic model. Auto metering uses the
/// unchanged baseline source so it cannot cancel the user's source exposure adjustment.
nonisolated enum SourceImageRenderer {
    enum Intent: Hashable { case sceneLinear, developedPhoto }
    /// Preview-size pixels live in `pixels`. A full-size export keeps them in `store` instead.
    /// A part of the prepared image, in its pixels from the top left. `.measure` decodes
    /// nothing and reports the size the whole image would have.
    enum Region: Sendable { case measure, rect(x: Int, y: Int, width: Int, height: Int) }
    struct Input: Sendable {
        let pixels: [SIMD4<Float>], width: Int, height: Int
        var store: PixelStore? = nil
    }
    enum Failure: LocalizedError {
        case decode, raw
        var errorDescription: String? {
            switch self {
            case .decode:
                String(
                    localized: "source_image.the_source_photo_could_not_be_decoded",
                    defaultValue: "The source photo could not be decoded.")
            case .raw:
                String(
                    localized: "source_image.this_raw_file_is_not_supported_by",
                    defaultValue: "This RAW file is not supported by the system decoder.")
            }
        }
    }
    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let context = CIContext(options: [
        .workingColorSpace: linear, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
    ])

    /// Owned by one preview resolution inside PhotoRenderer's actor. Mutable RAW filters
    /// never cross workers; export uses the uncached one-shot path instead.
    final class Decoder {
        lazy var context = CIContext(options: [
            .workingColorSpace: SourceImageRenderer.linear, .workingFormat: CIFormat.RGBAf,
            .cacheIntermediates: true,
        ])
        private var filters: [Intent: (CIRAWFilter, Float, Float)] = [:]
        private var maximum: Int?
        func raw(
            _ data: Data, type: String?, intent: Intent, maximum: Int
        ) throws -> (CIRAWFilter, Float, Float) {
            if self.maximum != maximum { filters.removeAll(); self.maximum = maximum }
            if let cached = filters[intent] { return cached }
            let result = try SourceImageRenderer.raw(data, type: type, intent: intent, maximum: maximum)
            filters[intent] = result
            return result
        }
    }

    private static func raw(
        _ data: Data, type: String?, intent: Intent, maximum: Int
    ) throws -> (CIRAWFilter, Float, Float) {
        guard let raw = CIRAWFilter(imageData: data, identifierHint: type),
            raw.nativeSize.width > 0, raw.nativeSize.height > 0
        else { throw Failure.raw }
        raw.scaleFactor = Float(
            min(1, Double(maximum) / max(raw.nativeSize.width, raw.nativeSize.height)))
        if intent == .sceneLinear {
            raw.baselineExposure = 0
            raw.shadowBias = 0
            raw.boostAmount = 0
            raw.localToneMapAmount = 0
            raw.isGamutMappingEnabled = false
        }
        return (raw, raw.neutralTemperature, raw.neutralTint)
    }

    static func prepare(
        data: Data?, fallback: CGImage, recipe: EditRecipe, maximum: Int,
        renderedSource: CIImage? = nil, sourceType: String? = nil, intent: Intent? = nil,
        description: PhotoSource.Description? = nil, decoder: Decoder? = nil,
        framing: EditRecipe? = nil, targetSize: CGSize? = nil, allowsStore: Bool = false,
        region: Region? = nil
    ) throws -> Input {
        try Task.checkCancellation()
        return try autoreleasepool {
            try preparePixels(
                data: data, fallback: fallback, recipe: recipe, maximum: maximum,
                renderedSource: renderedSource, sourceType: sourceType,
                intent: intent
                    ?? (recipe.inputMode == .spektrafilm ? .sceneLinear : .developedPhoto),
                description: description, decoder: decoder, framing: framing, targetSize: targetSize,
                allowsStore: allowsStore, region: region)
        }
    }
    private static func preparePixels(
        data: Data?, fallback: CGImage, recipe: EditRecipe, maximum: Int, renderedSource: CIImage?,
        sourceType: String?, intent: Intent, description known: PhotoSource.Description?, decoder: Decoder?,
        framing: EditRecipe?, targetSize: CGSize?, allowsStore: Bool, region: Region?
    ) throws
        -> Input
    {
        var image: CIImage
        var rawInput = false
        let description = known ?? data.flatMap { PhotoSource.describe($0, typeHint: sourceType) }
        if data != nil && description == nil { throw Failure.decode }
        if renderedSource == nil, let data, description?.isRAW == true {
            let (raw, temperature, tint) = try decoder?.raw(
                data, type: description?.type, intent: intent, maximum: maximum)
                ?? Self.raw(data, type: description?.type, intent: intent, maximum: maximum)
            rawInput = true
            // The film model needs scene light. Photo LUTs expect a rendered sRGB photograph:
            // retain the decoder's per-file baseline and default look for that input contract.
            // A fixed ProRAW EV offset cannot replace the DNG's image-specific rendering tags.
            // RAW exposure belongs before the decoder's nonlinear development look.
            let exposure = Float(recipe.source.exposureEV)
            let white = recipe.temperature.map(Float.init) ?? temperature
            let adjustedTint = min(max(tint + Float(recipe.source.tint), -150), 150)
            if raw.exposure != exposure { raw.exposure = exposure }
            if raw.neutralTemperature != white { raw.neutralTemperature = white }
            if raw.neutralTint != adjustedTint { raw.neutralTint = adjustedTint }
            guard let output = raw.outputImage else { throw Failure.raw }
            image = output
        } else {
            if let renderedSource {
                image = renderedSource
            } else if let data,
                let native = CIImage(
                    data: data,
                    options: [
                        .applyOrientationProperty: true,
                        .expandToHDR: intent == .sceneLinear,
                        .toneMapHDRtoSDR: false,
                    ])
            {
                // The display thumbnail is 8-bit. Processing decodes original pixels before downsampling.
                image = PhotoSource.resized(
                    intent == .developedPhoto ? PhotoSource.toSDR(native) : native,
                    maximum: maximum)
            } else {
                image = CIImage(cgImage: fallback)
                if intent == .developedPhoto {
                    let recorded = fallback.contentHeadroom
                    let headroom = recorded > 0 ? recorded : fallback.calculatedContentHeadroom
                    if headroom > 1 {
                        image = image.applyingFilter(
                            "CIToneMapHeadroom",
                            parameters: [
                                "inputSourceHeadroom": headroom, "inputTargetHeadroom": 1.0,
                            ])
                    }
                }
            }
        }
        if !rawInput && recipe.source.exposureEV != 0 {
            image = image.applyingFilter(
                "CIExposureAdjust", parameters: [kCIInputEVKey: recipe.source.exposureEV])
        }
        if !rawInput {
            if recipe.source.warmth != 0 || recipe.source.tint != 0 {
                // Rendered RGB has a defined display white, not a recoverable camera Kelvin value.
                let kelvin = 1_000_000 / (1_000_000 / 6500 + recipe.source.warmth)
                image = image.applyingFilter(
                    "CITemperatureAndTint",
                    parameters: [
                        "inputNeutral": CIVector(x: 6500, y: 0),
                        "inputTargetNeutral": CIVector(x: kelvin, y: recipe.source.tint),
                    ])
            }
        }
        if recipe.source.saturation != 1 {
            image = image.applyingFilter(
                "CIColorControls", parameters: [kCIInputSaturationKey: recipe.source.saturation])
        }
        if let framing {
            image = GeometryRenderer.transformed(image, geometry: framing.geometry)
            let crop = framing.crop.pixelRect(in: image.extent.size)
            // CropSelection uses top-left coordinates; Core Image uses bottom-left coordinates.
            image = image.cropped(to: CGRect(x: crop.minX, y: image.extent.height - crop.maxY,
                                             width: crop.width, height: crop.height))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        if let targetSize {
            image = image.transformed(by: CGAffineTransform(scaleX: targetSize.width / image.extent.width,
                                                            y: targetSize.height / image.extent.height))
        }
        image = image.composited(over: CIImage(color: CIColor.black).cropped(to: image.extent))
        image = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let width = Int(image.extent.width.rounded())
        let height = Int(image.extent.height.rounded())
        guard width > 0, height > 0 else { throw Failure.decode }
        if let region {
            guard case .rect(let x, let y, let w, let h) = region else {
                return .init(pixels: [], width: width, height: height)
            }
            guard x >= 0, y >= 0, w > 0, h > 0, x + w <= width, y + h <= height else {
                throw Failure.decode
            }
            // Core Image evaluates only this rectangle of the scaled source.
            let part = image.cropped(
                to: CGRect(x: x, y: height - y - h, width: w, height: h)
            ).transformed(by: CGAffineTransform(translationX: -CGFloat(x), y: -CGFloat(height - y - h)))
            let store = try PixelStore.render(
                part, width: w, height: h, context: decoder?.context ?? context, colorSpace: linear)
            guard store.isValid() else { throw Failure.decode }
            return .init(pixels: [], width: w, height: h, store: store)
        }
        if allowsStore && PixelStore.isLarge(width: width, height: height) {
            // Full-size sources decode straight into file-backed storage.
            let store = try PixelStore.render(
                image, width: width, height: height, context: decoder?.context ?? context,
                colorSpace: linear)
            guard store.isValid() else { throw Failure.decode }
            return .init(pixels: [], width: width, height: height, store: store)
        }
        var pixels = Array(repeating: SIMD4<Float>.zero, count: width * height)
        pixels.withUnsafeMutableBytes { bytes in
            (decoder?.context ?? context).render(
                image, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
                colorSpace: linear)
        }
        guard pixels.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w > 0.99 })
        else {
            throw Failure.decode
        }
        return .init(pixels: pixels, width: width, height: height)
    }

    /// Materialize the unadjusted floating-point proxy once; exposure changes reuse its headroom.
    static func image(_ input: Input) -> CIImage {
        if let store = input.store { return store.ciImage() }
        let data = input.pixels.withUnsafeBytes { Data($0) }
        return CIImage(
            bitmapData: data, bytesPerRow: input.width * 16,
            size: CGSize(width: input.width, height: input.height), format: .RGBAf,
            colorSpace: linear)
    }

    static func workingImage(_ input: Input) throws -> CGImage {
        if let store = input.store { return try store.image(colorSpace: linear) }
        let source = image(input)
        guard
            let frame = context.createCGImage(
                source, from: source.extent, format: .RGBAf, colorSpace: linear, deferred: false)
        else { throw Failure.decode }
        return frame
    }
    /// Blend in linear light, then return the same explicit SDR sRGB boundary as film output.
    static func blend(film: CGImage, source: Input, amount: Double) throws -> CGImage {
        if amount >= 1 { return film }
        return try blend(film: film, sourceImage: workingImage(source), amount: amount)
    }
    static func blend(film: CGImage, sourceImage: CGImage, amount: Double) throws -> CGImage {
        if amount >= 1 { return film }
        let original = PixelStore.ciImage(sourceImage)

        let output = original.applyingFilter(
            "CIDissolveTransition",
            parameters: [
                kCIInputTargetImageKey: PixelStore.ciImage(film),
                kCIInputTimeKey: min(max(amount, 0), 1),
            ])
        if PixelStore.isLarge(width: film.width, height: film.height) {
            return try PixelStore.render(
                output, width: film.width, height: film.height, context: context, colorSpace: linear
            ).image(colorSpace: linear)
        }
        guard
            let image = context.createCGImage(
                output, from: original.extent, format: .RGBAf,
                colorSpace: linear, deferred: false)
        else { throw Failure.decode }
        return image
    }
}
