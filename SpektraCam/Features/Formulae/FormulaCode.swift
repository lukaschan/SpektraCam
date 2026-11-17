import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import Vision

/// A formula link as a QR code: the dark modules, so it draws sharp at any size and in the
/// card's own ink.
struct FormulaCode: Equatable {
    /// Modules per side, without a quiet zone.
    let side: Int
    private let dark: [Bool]
    func isDark(_ x: Int, _ y: Int) -> Bool { dark[y * side + x] }

    /// The finest code the card prints at four pixels a module. A link that needs more
    /// modules at medium error correction gives some correction up for a coarser code: a
    /// shared picture is shrunk far more often than it is torn.
    static let coarseSide = 113

    /// Nil when the text is longer than a code should carry.
    init?(_ text: String) {
        guard text.utf8.count <= FormulaLink.codeLimit else { return nil }
        guard let medium = Self(text, correction: "M") else { return nil }
        self = medium.side <= Self.coarseSide ? medium : Self(text, correction: "L") ?? medium
    }
    private init?(_ text: String, correction: String) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correction
        guard let image = filter.outputImage else { return nil }
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        guard width == height, width > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height)
        CIContext(options: [.useSoftwareRenderer: true]).render(
            image, toBitmap: &pixels, rowBytes: width, bounds: image.extent, format: .L8,
            colorSpace: CGColorSpace(name: CGColorSpace.linearGray))
        // The generator pads the symbol with white. Keep the symbol alone; the card's paper is its margin.
        let marked = (0..<width * height).filter { pixels[$0] < 128 }
        guard let first = marked.first, let last = marked.last else { return nil }
        let columns = marked.map { $0 % width }
        let (left, top) = (columns.min()!, first / width)
        let size = max(columns.max()! - left, last / width - top) + 1
        side = size
        dark = (0..<size * size).map { index in
            let (x, y) = (left + index % size, top + index / size)
            return x < width && y < height && pixels[y * width + x] < 128
        }
    }

    /// Every QR code's text in an image, most likely a saved formula card or a screenshot.
    static func read(_ image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        if (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
            let found = request.results?.compactMap(\.payloadStringValue), !found.isEmpty
        {
            return found
        }
        // A second reader for a picture Vision finds nothing in.
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: CIImage(cgImage: image)) ?? []).compactMap {
            ($0 as? CIQRCodeFeature)?.messageString
        }
    }
    /// The formula file a picture's code carries.
    static func file(inImage data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 3000,
                ] as CFDictionary)
        else { throw FormulaLink.Failure.noCode }
        let links = read(image).filter(FormulaLink.claims)
        guard let link = links.first else { throw FormulaLink.Failure.noCode }
        return try FormulaLink.file(from: link)
    }
}

/// The code in one colour on a clear ground. Each module is a whole number of pixels, so a
/// picture of it stays readable when it is shrunk; the code is centred in what is left over.
/// The ground around it is the quiet zone: keep four modules of it clear.
struct FormulaCodeView: View {
    let code: FormulaCode
    /// Pixels per point of the picture this is drawn into.
    var pixelScale: CGFloat = 3
    /// Points per module in a square of this side.
    static func pitch(_ code: FormulaCode, side: CGFloat, pixelScale: CGFloat) -> CGFloat {
        max(1, (side * pixelScale / CGFloat(code.side)).rounded(.down)) / pixelScale
    }
    var body: some View {
        Canvas { context, size in
            let unit = Self.pitch(code, side: min(size.width, size.height), pixelScale: pixelScale)
            let inset = ((min(size.width, size.height) - unit * CGFloat(code.side)) / 2 * pixelScale).rounded() / pixelScale
            var path = Path()
            for y in 0..<code.side {
                var x = 0
                while x < code.side {
                    guard code.isDark(x, y) else { x += 1; continue }
                    var end = x
                    while end + 1 < code.side, code.isDark(end + 1, y) { end += 1 }
                    path.addRect(
                        CGRect(
                            x: inset + CGFloat(x) * unit, y: inset + CGFloat(y) * unit,
                            width: CGFloat(end - x + 1) * unit, height: unit))
                    x = end + 1
                }
            }
            // Whole pixels: smoothed edges would leave hairlines between neighbouring modules.
            context.fill(path, with: .foreground, style: FillStyle(antialiased: false))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
