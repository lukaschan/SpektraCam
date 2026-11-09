import CoreGraphics
import CoreImage
import Foundation
import Metal

/// Float grading precedes the SDR display boundary. Older recipes retain their curve algorithm.
nonisolated enum ToneRenderer {
    enum Failure: LocalizedError {
        case parameters, render
        var errorDescription: String? {
            String(
                localized: "tone.the_image_adjustment_could_not_be_rendered",
                defaultValue: "The image adjustment could not be rendered.")
        }
    }
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let display = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [
        .workingColorSpace: linear, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
    ])
    private static let gpu = try? GradeKernel()

    /// Versioned code-value curve; older grades retain their original formula.
    static func curve(_ value: Double, tone: EditRecipe.Tone) -> Double {
        let p = min(max(tone.pivot, 0.0001), 0.9999)
        if value <= 0 || (value >= 1 && tone.algorithm < 5) { return value }
        if tone.algorithm >= 5 {
            let x = value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            let pivot = p <= 0.04045 ? p / 12.92 : pow((p + 0.055) / 1.055, 2.4)
            let width = max(1, abs(tone.shadows - tone.highlights) / 4)
            let odds = exp2(log2(x / 0.18) / width)
            let weight = odds / (1 + odds)
            let stops = tone.shadows * (1 - weight) + tone.highlights * weight
            let lifted = x * exp2(stops)
            let bend = (tone.contrast - 1) * 4 * tanh(log2(lifted / pivot) / 4)
            let output = x * exp2(stops + bend)
            return output <= 0.0031308 ? output * 12.92 : 1.055 * pow(output, 1 / 2.4) - 0.055
        }
        if tone.algorithm >= 4 {
            let lifted = value <= p ? p * pow(value / p, exp2(-tone.shadows)) : value
            if tone.contrast == 1 { return lifted }
            let slope = tone.contrast / max(2 - tone.contrast, 0.01)
            let center = log(p / (1 - p))
            let odds = slope * (log(lifted / (1 - lifted)) - center) + center
            return odds >= 0 ? 1 / (1 + exp(-odds)) : exp(odds) / (1 + exp(odds))
        }
        if value <= p {
            let t = value / p
            let lifted =
                tone.algorithm >= 3
                ? pow(t, exp2(-tone.shadows)) : t + tone.shadows * t * (1 - t) * (1 - t)
            return p * pow(lifted, tone.contrast)
        }
        let t = (1 - value) / (1 - p)
        let shifted = tone.algorithm == 1 ? t - tone.highlights * t * (1 - t) * (1 - t) : t
        return 1 - (1 - p) * pow(shifted, tone.contrast)
    }
    static func working(
        _ image: CGImage, tone: EditRecipe.Tone,
        luts: [CubeLUT.Application] = [], residual: (CGImage, CGImage)? = nil,
        monochromeResidual: Bool = false, normalizationEV: Double = 0
    ) throws -> CGImage {
        try RawAdjustments.validate(tone)
        guard luts.count <= 2, luts.allSatisfy({ $0.mix.isFinite && (0...1).contains($0.mix) })
        else {
            throw Failure.parameters
        }
        if tone.isIdentity && luts.isEmpty && residual == nil { return image }
        guard let gpu else { throw Failure.render }
        if max(image.width, image.height) > 2048 {
            return try tiledWorking(
                image, tone: tone, luts: luts, residual: residual,
                monochromeResidual: monochromeResidual, normalizationEV: normalizationEV)
        }
        return try gpu.render(
            image, tone: tone, luts: luts, residual: residual,
            monochromeResidual: monochromeResidual, normalizationEV: normalizationEV)
    }
    /// Grade is pointwise: strips preserve the exact LUT/tone/noise math without full-frame textures.
    static func tiledWorking(
        _ image: CGImage, tone: EditRecipe.Tone,
        luts: [CubeLUT.Application] = [], residual: (CGImage, CGImage)? = nil,
        monochromeResidual: Bool = false, normalizationEV: Double = 0
    ) throws -> CGImage {
        guard let gpu else { throw Failure.render }
        var pixels = Data(count: image.width * image.height * 16)
        try pixels.withUnsafeMutableBytes { bytes in
            for y in stride(from: 0, to: image.height, by: 128) {
                try Task.checkCancellation()
                try autoreleasepool {
                    let rows = min(128, image.height - y)
                    let rect = CGRect(x: 0, y: y, width: image.width, height: rows)
                    guard let strip = image.cropping(to: rect) else { throw Failure.render }
                    let noise: (CGImage, CGImage)?
                    if let residual {
                        guard let dirty = residual.0.cropping(to: rect),
                            let clean = residual.1.cropping(to: rect)
                        else { throw Failure.render }
                        noise = (dirty, clean)
                    } else {
                        noise = nil
                    }
                    let graded = try gpu.render(
                        strip, tone: tone, luts: luts, residual: noise,
                        monochromeResidual: monochromeResidual, normalizationEV: normalizationEV)
                    context.render(
                        CIImage(cgImage: graded),
                        toBitmap: bytes.baseAddress!.advanced(by: y * image.width * 16),
                        rowBytes: image.width * 16,
                        bounds: CGRect(x: 0, y: 0, width: image.width, height: rows),
                        format: .RGBAf, colorSpace: linear)
                }
            }
        }
        return try PhotoColorBridge.workingImage(
            pixels, width: image.width, height: image.height, encoded: false)
    }
    static func render(
        _ image: CGImage, tone: EditRecipe.Tone,
        luts: [CubeLUT.Application] = [], residual: (CGImage, CGImage)? = nil,
        monochromeResidual: Bool = false
    ) throws -> CGImage {
        if tone.isIdentity && luts.isEmpty && residual == nil && image.bitsPerComponent == 8
            && image.colorSpace?.name == CGColorSpace.sRGB
        {
            return image
        }
        return try resolve(
            working(
                image, tone: tone, luts: luts, residual: residual,
                monochromeResidual: monochromeResidual)
        )
    }
    static func resolve(_ image: CGImage) throws -> CGImage {
        let input = CIImage(cgImage: image)
        guard
            let result = context.createCGImage(
                input, from: input.extent, format: .RGBA8,
                colorSpace: display, deferred: false)
        else { throw Failure.render }
        return result
    }
}

/// One cached native compute pass; no pixel-array round trip during a grading drag.
nonisolated private final class GradeKernel: @unchecked Sendable {
    private let device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLComputePipelineState
    private let context = CIContext(options: [
        .workingColorSpace: ToneRenderer.linear, .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false,
    ])
    private let lock = NSLock()
    private var input: MTLTexture?, output: MTLTexture?, cachedImage: CGImage?
    private var residualTextures: [MTLTexture] = []
    private var residualImages: [CGImage] = []
    private var lutTextures: [String: MTLTexture] = [:]
    private let identity: MTLTexture
    private let invalid: MTLBuffer
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
        else {
            throw ToneRenderer.Failure.render
        }
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let function = library.makeFunction(name: "grade") else {
            throw ToneRenderer.Failure.render
        }
        self.device = device
        self.queue = queue
        pipeline = try device.makeComputePipelineState(function: function)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = 2
        descriptor.height = 2
        descriptor.depth = 2
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let identity = device.makeTexture(descriptor: descriptor),
            let invalid = device.makeBuffer(length: 4, options: .storageModeShared)
        else { throw ToneRenderer.Failure.render }
        self.identity = identity
        self.invalid = invalid
        let values = Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: 8)
        values.withUnsafeBytes {
            identity.replace(
                region: MTLRegionMake3D(0, 0, 0, 2, 2, 2), mipmapLevel: 0, slice: 0,
                withBytes: $0.baseAddress!, bytesPerRow: 32, bytesPerImage: 64)
        }
    }
    func render(
        _ image: CGImage, tone: EditRecipe.Tone, luts: [CubeLUT.Application],
        residual: (CGImage, CGImage)?,
        monochromeResidual: Bool, normalizationEV: Double = 0
    ) throws -> CGImage {
        lock.lock()
        defer {
            if max(image.width, image.height) > 2048 {
                input = nil
                output = nil
                cachedImage = nil
                residualTextures = []
                residualImages = []
            }
            lock.unlock()
        }
        if input?.width != image.width || input?.height != image.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: image.width, height: image.height,
                mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            input = device.makeTexture(descriptor: descriptor)
            output = device.makeTexture(descriptor: descriptor)
            cachedImage = nil
            residualTextures = []
            residualImages = []
        }
        guard let input, let output, let command = queue.makeCommandBuffer() else {
            throw ToneRenderer.Failure.render
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if cachedImage !== image {
            context.render(
                CIImage(cgImage: image), to: input, commandBuffer: command, bounds: bounds,
                colorSpace: ToneRenderer.linear)
        }
        var residualInputs = [input, input]
        if let residual {
            let frames = [residual.0, residual.1]
            guard frames.allSatisfy({ $0.width == image.width && $0.height == image.height }) else {
                throw ToneRenderer.Failure.parameters
            }
            if residualTextures.isEmpty {
                let d = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba32Float, width: image.width, height: image.height,
                    mipmapped: false)
                // Core Image can use a compute encoder to fill these textures.
                d.usage = [.shaderRead, .shaderWrite, .renderTarget]
                d.storageMode = .private
                guard let a = device.makeTexture(descriptor: d),
                    let b = device.makeTexture(descriptor: d)
                else { throw ToneRenderer.Failure.render }
                residualTextures = [a, b]
            }
            for i in 0..<2 where residualImages.count != 2 || residualImages[i] !== frames[i] {
                context.render(
                    CIImage(cgImage: frames[i]), to: residualTextures[i], commandBuffer: command,
                    bounds: bounds, colorSpace: ToneRenderer.linear)
            }
            residualImages = frames
            residualInputs = residualTextures
        } else {
            residualTextures = []
            residualImages = []
        }
        var activeTextures: [String: MTLTexture] = [:]
        var slots: [MTLTexture] = []
        var parameters: [Float] = [
            Float(tone.contrast), Float(tone.pivot), Float(tone.shadows), Float(tone.highlights),
            Float(tone.exposureEV), Float(tone.algorithm), tone.monochrome ? 1 : 0,
            residual == nil ? 0 : (monochromeResidual ? 2 : 1),
        ]
        for index in 0..<2 {
            if index < luts.count {
                let item = luts[index]
                let cube = item.cube
                let texture =
                    try activeTextures[cube.id] ?? lutTextures[cube.id] ?? makeTexture(cube)
                activeTextures[cube.id] = texture
                slots.append(texture)
                parameters += [
                    cube.minimum.x, cube.minimum.y, cube.minimum.z, Float(item.mix), cube.maximum.x,
                    cube.maximum.y, cube.maximum.z, Float(cube.size),
                ]
            } else {
                slots.append(identity)
                parameters += [0, 0, 0, 0, 1, 1, 1, 2]
            }
        }
        parameters += [Float(normalizationEV), 0, 0, 0]
        lutTextures = activeTextures
        invalid.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw ToneRenderer.Failure.render
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(residualInputs[0], index: 2)
        encoder.setTexture(residualInputs[1], index: 3)
        encoder.setTexture(slots[0], index: 4)
        encoder.setTexture(slots[1], index: 5)
        encoder.setBuffer(invalid, offset: 0, index: 1)

        parameters.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        let width = pipeline.threadExecutionWidth
        encoder.dispatchThreads(
            MTLSize(width: image.width, height: image.height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: width, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / width),
                depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed, invalid.contents().load(as: UInt32.self) == 0,
            let result = CIImage(mtlTexture: output, options: [.colorSpace: ToneRenderer.linear]),
            let frame = context.createCGImage(
                result, from: bounds, format: .RGBAf, colorSpace: ToneRenderer.linear,
                deferred: false)
        else {
            cachedImage = nil
            throw ToneRenderer.Failure.render
        }
        cachedImage = image
        return frame
    }
    private func makeTexture(_ cube: CubeLUT) throws -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba32Float
        d.width = cube.size
        d.height = cube.size
        d.depth = cube.size
        d.storageMode = .shared
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else {
            throw ToneRenderer.Failure.render
        }
        cube.values.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, cube.size, cube.size, cube.size), mipmapLevel: 0,
                slice: 0,
                withBytes: $0.baseAddress!, bytesPerRow: cube.size * 16,
                bytesPerImage: cube.size * cube.size * 16)
        }
        return texture
    }
    private static let shader = """
            #include <metal_stdlib>
            using namespace metal;
        """ + RawAdjustments.shader + """
                float3 tetra(texture3d<float,access::read> cube, float3 t, uint n) {
                float3 v=clamp(t,0.0f,1.0f)*float(n-1);
                uint3 lo=uint3(floor(v)), hi=min(lo+1,uint3(n-1));
                float3 f=v-float3(lo), a=cube.read(lo).rgb, z=cube.read(hi).rgb;
                if(f.r>=f.g) {
                    float3 r=cube.read(uint3(hi.x,lo.y,lo.z)).rgb;
                    if(f.g>=f.b) { float3 rg=cube.read(uint3(hi.x,hi.y,lo.z)).rgb; return a+f.r*(r-a)+f.g*(rg-r)+f.b*(z-rg); }
                    float3 rb=cube.read(uint3(hi.x,lo.y,hi.z)).rgb;
                    if(f.r>=f.b) return a+f.r*(r-a)+f.b*(rb-r)+f.g*(z-rb);
                    float3 b=cube.read(uint3(lo.x,lo.y,hi.z)).rgb; return a+f.b*(b-a)+f.r*(rb-b)+f.g*(z-rb);
                }
                float3 g=cube.read(uint3(lo.x,hi.y,lo.z)).rgb;
                if(f.r>=f.b) { float3 rg=cube.read(uint3(hi.x,hi.y,lo.z)).rgb; return a+f.g*(g-a)+f.r*(rg-g)+f.b*(z-rg); }
                float3 gb=cube.read(uint3(lo.x,hi.y,hi.z)).rgb;
                if(f.g>=f.b) return a+f.g*(g-a)+f.b*(gb-g)+f.r*(z-gb);
                float3 b=cube.read(uint3(lo.x,lo.y,hi.z)).rgb; return a+f.b*(b-a)+f.g*(gb-b)+f.r*(z-gb);
            }
            float3 look(float3 rgb, texture3d<float,access::read> cube, float4 low, float4 high) {
                if(low.w==0) return rgb;
                float3 code=float3(rawEncode(rgb.r),rawEncode(rgb.g),rawEncode(rgb.b));
                float3 bounded=clamp(code,low.xyz,high.xyz);
                float3 mapped=tetra(cube,(bounded-low.xyz)/(high.xyz-low.xyz),uint(high.w));
                // A photo LUT defines only its declared domain. Input beyond it samples
                // the boundary; adding an arbitrary residual changes the authored transform.
                float3 linear=float3(rawDecode(mapped.r),rawDecode(mapped.g),rawDecode(mapped.b));
                return mix(rgb,linear,low.w);
            }
            kernel void grade(texture2d<float,access::read> source [[texture(0)]],
                              texture2d<float,access::write> target [[texture(1)]],
                              texture2d<float,access::read> dirty [[texture(2)]],
                              texture2d<float,access::read> clean [[texture(3)]],
                              texture3d<float,access::read> first [[texture(4)]],
                              texture3d<float,access::read> second [[texture(5)]],
                              constant float4 *p [[buffer(0)]], device atomic_uint *invalid [[buffer(1)]], uint2 id [[thread_position_in_grid]]) {
                if(id.x>=source.get_width() || id.y>=source.get_height()) return;
                float3 rgb=applyRaw(source.read(id).rgb,p,p[6].x);
                rgb=look(rgb,first,p[2],p[3]); rgb=look(rgb,second,p[4],p[5]);
                if(p[1].w!=0) {
                    // App RGB adapter: negative-film density noise becomes log exposure.
                    // The physical film path retains its full print/scan calculation.
                    float3 density=dirty.read(id).rgb-clean.read(id).rgb;
                    if(!all(isfinite(density)))atomic_store_explicit(invalid,1u,memory_order_relaxed);
                    if(p[1].w>1.5f)density=float3(dot(density,float3(0.2126f,0.7152f,0.0722f)));
                    float3 magnitude=abs(rgb);
                    // Limit only the representable float exponent. Preserve zero and sign:
                    // grain cannot create colored light in a black LUT output.
                    float3 exponent=clamp(log2(max(magnitude,float3(0x1p-126f)))+density*3.32192809489f,float3(-126),float3(125));
                    rgb=select(sign(rgb)*exp2(exponent),float3(0),magnitude==float3(0));
                }
                if(p[1].z!=0) rgb=float3(dot(rgb,float3(0.2126f,0.7152f,0.0722f)));
                if(!all(isfinite(rgb))) atomic_store_explicit(invalid,1u,memory_order_relaxed);
                target.write(float4(rgb,1),id);
            }
            """
}
