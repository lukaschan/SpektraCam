import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import ObjectiveC

/// Full-resolution pixels held in an unlinked, memory-mapped scratch file.
/// File-backed pages can be written out and evicted by the system, so a large export
/// does not grow the app's memory footprint with image size.
nonisolated final class PixelStore: @unchecked Sendable {
    enum Format: Sendable {
        case float, byte
        var bytesPerPixel: Int { self == .float ? 16 : 4 }
    }
    struct Failure: LocalizedError {
        var errorDescription: String? {
            String(
                localized: "pixel_store.not_enough_storage",
                defaultValue:
                    "There is not enough free storage to render this size. Free some space or choose a smaller export size.")
        }
    }
    /// Images above this size are rendered in tiles through file-backed storage.
    static let tilingThreshold = 2048 * 2048
    static func isLarge(width: Int, height: Int) -> Bool { width * height > tilingThreshold }

    let width: Int, height: Int, format: Format
    let base: UnsafeMutableRawPointer
    private let mapped: Int
    /// Colour space of the bitmap handed out by `image(colorSpace:)`.
    private(set) var colorSpace: CGColorSpace?
    private static var ownerKey: UInt8 = 0
    var rowBytes: Int { width * format.bytesPerPixel }
    var length: Int { rowBytes * height }

    init(width: Int, height: Int, format: Format) throws {
        guard width > 0, height > 0 else { throw Failure() }
        self.width = width
        self.height = height
        self.format = format
        let bytes = width * height * format.bytesPerPixel
        let page = Int(getpagesize())
        mapped = (bytes + page - 1) / page * page
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Spektrafilm-Scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent(UUID().uuidString + ".pixels").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw Failure() }
        // The mapping keeps the storage alive; nothing remains on disk after a crash.
        unlink(path)
        defer { close(descriptor) }
        // Reserve the blocks first: writing an unbacked page on a full disk raises SIGBUS.
        var reservation = fstore_t(
            fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE, fst_offset: 0,
            fst_length: off_t(mapped), fst_bytesalloc: 0)
        guard fcntl(descriptor, F_PREALLOCATE, &reservation) != -1,
            ftruncate(descriptor, off_t(mapped)) == 0,
            let address = mmap(nil, mapped, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0),
            address != MAP_FAILED
        else { throw Failure() }
        base = address
    }
    deinit { munmap(base, mapped) }

    /// Zero-copy bitmap. The image retains this store.
    func image(colorSpace: CGColorSpace) throws -> CGImage {
        let owner = Unmanaged.passRetained(self)
        guard
            let provider = CGDataProvider(
                dataInfo: owner.toOpaque(), data: base, size: length,
                releaseData: { info, _, _ in
                    Unmanaged<PixelStore>.fromOpaque(info!).release()
                })
        else {
            owner.release()
            throw Failure()
        }
        let float = format == .float
        // Alpha is one everywhere, so the float layout matches Core Image's own RGBAf bitmaps.
        let info: CGBitmapInfo =
            float
            ? [
                .floatComponents, .byteOrder32Little,
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            ]
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard
            let image = CGImage(
                width: width, height: height, bitsPerComponent: float ? 32 : 8,
                bitsPerPixel: float ? 128 : 32, bytesPerRow: rowBytes, space: colorSpace,
                bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { throw Failure() }
        self.colorSpace = colorSpace
        objc_setAssociatedObject(image, &Self.ownerKey, self, .OBJC_ASSOCIATION_RETAIN)
        return image
    }
    /// The store behind a bitmap made by `image(colorSpace:)`, if any.
    static func of(_ image: CGImage) -> PixelStore? {
        objc_getAssociatedObject(image, &ownerKey) as? PixelStore
    }
    /// Core Image view of some rows, read straight from the mapping. Row zero is the top.
    func ciImage(rows: Range<Int>? = nil) -> CIImage {
        let rows = rows ?? 0..<height
        let owner = self
        let data = Data(
            bytesNoCopy: base.advanced(by: rows.lowerBound * rowBytes),
            count: rows.count * rowBytes, deallocator: .custom { _, _ in _ = owner })
        return CIImage(
            bitmapData: data, bytesPerRow: rowBytes,
            size: CGSize(width: width, height: rows.count),
            format: format == .float ? .RGBAf : .RGBA8,
            colorSpace: colorSpace ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
    }
    /// Core Image input for any working bitmap; store-backed ones are never copied.
    static func ciImage(_ image: CGImage) -> CIImage {
        of(image)?.ciImage() ?? CIImage(cgImage: image)
    }

    /// Render an image whose extent starts at the origin. Core Image works in bands, so its
    /// working set stays independent of the image height.
    static func render(
        _ image: CIImage, width: Int, height: Int, context: CIContext, colorSpace: CGColorSpace,
        format: Format = .float
    ) throws -> PixelStore {
        let store = try PixelStore(width: width, height: height, format: format)
        store.colorSpace = colorSpace
        let band = max(256, 4_194_304 / max(width, 1))
        var y = 0
        while y < height {
            try Task.checkCancellation()
            let rows = min(band, height - y)
            autoreleasepool {
                // Core Image's origin is bottom-left; bitmap row zero is the top of the image.
                context.render(
                    image, toBitmap: store.base.advanced(by: y * store.rowBytes),
                    rowBytes: store.rowBytes,
                    bounds: CGRect(x: 0, y: height - y - rows, width: width, height: rows),
                    format: format == .float ? .RGBAf : .RGBA8, colorSpace: colorSpace)
            }
            y += rows
        }
        return store
    }

    /// Copy a rectangle of float pixels into a packed destination with the given row pitch.
    func read(x: Int, y: Int, width w: Int, height h: Int, into target: UnsafeMutableRawPointer) {
        precondition(format == .float && x >= 0 && y >= 0 && x + w <= width && y + h <= height)
        for row in 0..<h {
            memcpy(
                target.advanced(by: row * w * 16),
                base.advanced(by: ((y + row) * width + x) * 16), w * 16)
        }
    }
    /// Write float RGBA rows. A byte store clamps and rounds, matching an 8-bit sRGB resolve.
    func write(
        x: Int, y: Int, width w: Int, height h: Int, from source: UnsafeRawPointer,
        sourceRowBytes: Int
    ) {
        precondition(x >= 0 && y >= 0 && x + w <= width && y + h <= height)
        for row in 0..<h {
            let input = UnsafeMutableRawPointer(mutating: source.advanced(by: row * sourceRowBytes))
            let output = base.advanced(by: ((y + row) * width + x) * format.bytesPerPixel)
            if format == .float {
                memcpy(output, input, w * 16)
            } else {
                var from = vImage_Buffer(
                    data: input, height: 1, width: vImagePixelCount(w * 4), rowBytes: w * 16)
                var to = vImage_Buffer(
                    data: output, height: 1, width: vImagePixelCount(w * 4), rowBytes: w * 4)
                vImageConvert_PlanarFtoPlanar8(&from, &to, 1, 0, vImage_Flags(kvImageNoFlags))
            }
        }
    }
    /// Finite colour and opaque alpha, checked without building a second copy.
    func isValid() -> Bool {
        precondition(format == .float)
        let values = base.assumingMemoryBound(to: SIMD4<Float>.self)
        for i in 0..<(width * height) {
            let v = values[i]
            if !(v.x.isFinite && v.y.isFinite && v.z.isFinite && v.w > 0.99) { return false }
        }
        return true
    }
}
