import CoreGraphics
import Foundation

/// Output finishing only. Capture gates and film support will have their own geometry.
nonisolated struct PrintLayout: Codable, Equatable, Sendable {
    enum Paper: String, Codable, CaseIterable, Identifiable, Sendable {
        case asImage, fourBySix, fiveBySeven, eightByTen
        var id: Self { self }
        var shortToLong: Double? {
            switch self {
            case .asImage: nil
            case .fourBySix: 4.0 / 6
            case .fiveBySeven: 5.0 / 7
            case .eightByTen: 8.0 / 10
            }
        }
        /// Long side of the sheet in millimetres.
        var longMillimetres: Double? {
            switch self {
            case .asImage: nil
            case .fourBySix: 152.4
            case .fiveBySeven: 177.8
            case .eightByTen: 254
            }
        }
        var title: String {
            switch self {
            case .asImage: String(localized: "darkroom.as_image", defaultValue: "As image")
            case .fourBySix: "4 × 6"
            case .fiveBySeven: "5 × 7"
            case .eightByTen: "8 × 10"
            }
        }
    }
    enum Orientation: String, Codable, Sendable { case automatic, portrait, landscape }

    var paper = Paper.asImage
    var orientation = Orientation.automatic
    /// The easel's white border: the narrowest margin between the blades and the sheet's edge,
    /// as a fraction of the sheet's long side. The sheet stays fixed; the picture is inset, or
    /// with a negative border runs past the sheet's edge (Fill is the border that just covers it).
    /// Nil is automatic (see `resolvedMargin`).
    var margin: Double?
    static let marginRange = -0.2...0.2
    /// A film-edge enlarger print starts on a 5 × 7 sheet; a photo shown as itself stays as image.
    static var enlargerDefault: Self { var layout = Self(); layout.paper = .fiveBySeven; return layout }
    /// The automatic border: none for a photo shown as itself, a modest one on a sized sheet
    /// and around a film-edge enlarger print, whose blades should show.
    static let automaticMargin = 0.04
    /// Saved before the border went negative: the picture covers the sheet. Fill now sets
    /// `margin` to `PrintGeometry.fillMargin` instead.
    var fill = false
    /// Printed on a hand-set easel: blades set by eye leave uneven margins and, on a film-edge
    /// enlarger print, a projection a fraction of a degree off square. Off (the default) is a
    /// square, centred machine print.
    var handSet = false
    var easelSeed: UInt32 = 1
    /// The blades' edge (see `Easel.Kind`).
    var blade = Easel.Kind.natural
    func resolvedMargin(_ content: PrintGeometry.Content) -> Double {
        if fill { return 0 }
        if let margin { return min(max(margin, Self.marginRange.lowerBound), Self.marginRange.upperBound) }
        if case .enlarger = content { return Self.automaticMargin }
        return paper == .asImage ? 0 : Self.automaticMargin
    }
    /// The photo is shown as itself (a clean print needs no compositing).
    var isIdentity: Bool { paper == .asImage && orientation == .automatic && !fill && (margin ?? 0) == 0 }
    /// Nothing to save: identity placement with the default easel.
    var isDefault: Bool { isIdentity && margin == nil && !handSet && easelSeed == 1 && blade == .natural }
    /// Only what a film-edge render needs; paper and border drags never re-render the film.
    var easelOnly: Self {
        var easel = Self()
        easel.handSet = handSet
        easel.easelSeed = easelSeed
        easel.blade = blade
        return easel
    }

    init() {}
    enum CodingKeys: String, CodingKey { case paper, orientation, margin, fill, handSet, easelSeed, blade, scale }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        paper = try values.decodeIfPresent(Paper.self, forKey: .paper) ?? .asImage
        orientation = try values.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .automatic
        handSet = try values.decodeIfPresent(Bool.self, forKey: .handSet) ?? false
        easelSeed = try values.decodeIfPresent(UInt32.self, forKey: .easelSeed) ?? 1
        fill = try values.decodeIfPresent(Bool.self, forKey: .fill) ?? false
        blade = (try? values.decodeIfPresent(Easel.Kind.self, forKey: .blade)) ?? .natural
        if let margin = try values.decodeIfPresent(Double.self, forKey: .margin) {
            guard margin.isFinite, Self.marginRange.contains(margin) else {
                throw DecodingError.dataCorruptedError(forKey: .margin, in: values, debugDescription: "Unsupported border")
            }
            self.margin = margin
        } else if let scale = try values.decodeIfPresent(Double.self, forKey: .scale) {
            // Before the easel border: a scale below 1 left a margin, above it filled the sheet.
            guard scale.isFinite, scale > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .scale, in: values, debugDescription: "Unsupported print scale")
            }
            if scale > 1.001 { fill = true } else { margin = min((1 - scale) / 2, Self.marginRange.upperBound) }
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(paper, forKey: .paper); try c.encode(orientation, forKey: .orientation)
        try c.encodeIfPresent(margin, forKey: .margin); try c.encode(fill, forKey: .fill)
        try c.encode(handSet, forKey: .handSet); try c.encode(easelSeed, forKey: .easelSeed)
        try c.encode(blade, forKey: .blade)
    }
    func paperAspect(imageAspect: Double) -> Double {
        guard let ratio = paper.shortToLong else { return imageAspect }
        let landscape = orientation == .landscape
            || (orientation == .automatic && imageAspect > 1)
        return landscape ? 1 / ratio : ratio
    }
}

/// The enlarging easel, shared by every enlarger print. Its blades lie on the paper, a little above
/// the emulsion at their edge, so each casts a penumbra: the lens pupil (diameter f/N) seen from
/// the paper at the image distance f(1 + M) spans 1/(N(1 + M)), so a blade edge h above the
/// emulsion blurs over h / (N(1 + M)) on the paper, plus the paper's own light spread. The
/// blade's cut edge is not perfectly straight: it carries the same seeded wear profile as the
/// camera gate (`FilmEdgeNoise.wear`), smaller. Typical values, not one easel.
nonisolated enum Easel {
    static let bladeHeight = 4.5, aperture = 8.0, paperSpread = 0.05
    /// Width of the blade edge's light ramp on the paper, in millimetres.
    static func penumbra(magnification m: Double) -> Double {
        bladeHeight / (aperture * (1 + max(m, 0))) + paperSpread
    }
    /// Blade edges, like the gate types: new machined blades, ordinary use, nicked and bent.
    enum Kind: String, Codable, CaseIterable, Sendable {
        case precise, natural, worn
        var title: String {
            switch self {
            case .precise: String(localized: "darkroom.gate.precise", defaultValue: "Precise")
            case .natural: String(localized: "darkroom.gate.natural", defaultValue: "Natural")
            case .worn: String(localized: "darkroom.easel.worn", defaultValue: "Worn")
            }
        }
        /// Amplitude of the wear profile, in millimetres on the film (× magnification on paper).
        var wear: Double {
            switch self { case .precise: 0.004; case .natural: 0.009; case .worn: 0.02 }
        }
    }
    /// A hand-set easel lands a little off: up to this fraction of the sheet's long side.
    static let placement = 0.008
    /// Seeded unit values in [-1, 1] for a hand-set placement.
    static func jitter(_ seed: UInt32, _ k: Int32) -> Double {
        FilmEdgeNoise.unit(FilmEdgeNoise.hash(k, 77, seed)) * 2 - 1
    }
    /// Light the blades pass across a clean print whose picture fills `width` × `height` pixels
    /// (a 36 mm frame on its long side), as an 8-bit mask: the penumbra and worn edge of each
    /// blade, set just inside the projected picture. Only the edge bands are computed.
    static func mask(width: Int, height: Int, magnification: Double, kind: Kind, seed: UInt32) -> CGImage? {
        guard width > 2, height > 2, width <= 65_536, height <= 65_536, magnification > 0 else { return nil }
        let key = MaskKey(width: width, height: height, magnification: magnification, kind: kind, seed: seed)
        if let cached = MaskCache.shared.image(key) { return cached }
        let mmPerPixel = 36 / Double(max(width, height))
        let r = penumbra(magnification: magnification) / magnification / 2, wear = kind.wear
        let hx = Double(width) * mmPerPixel / 2 - r - wear, hy = Double(height) * mmPerPixel / 2 - r - wear
        guard hx > r, hy > r else { return nil }
        let band = Int(ceil((2 * (r + wear) + mmPerPixel) / mmPerPixel)) + 1
        let s1 = FilmEdgeGeometry.streamSeed(seed, 54), s2 = FilmEdgeGeometry.streamSeed(seed, 55)
        var pixels = [UInt8](repeating: 255, count: width * height)
        func shade(_ x: Int, _ y: Int) {
            let px = (Double(x) + 0.5) * mmPerPixel - Double(width) * mmPerPixel / 2
            let py = (Double(y) + 0.5) * mmPerPixel - Double(height) * mmPerPixel / 2
            let d = FilmEdgeNoise.box(px, py, hx, hy, 0.01) + wear * FilmEdgeNoise.wear(px, py, s1, s2)
            let pixelRadius = 0.56 * mmPerPixel
            pixels[y * width + x] = UInt8((FilmEdgeNoise.penumbra(d, max(r, pixelRadius)) * 255).rounded())
        }
        for y in 0..<height {
            if y < band || y >= height - band {
                for x in 0..<width { shade(x, y) }
            } else {
                for x in 0..<min(band, width) { shade(x, y) }
                for x in max(width - band, band)..<width { shade(x, y) }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        MaskCache.shared.insert(image, key)
        return image
    }
    private struct MaskKey: Hashable { let width: Int, height: Int, magnification: Double, kind: Kind, seed: UInt32 }
    /// The preview, loupe and export ask for the same few masks repeatedly.
    private final class MaskCache: @unchecked Sendable {
        static let shared = MaskCache()
        private let lock = NSLock()
        private var entries: [(MaskKey, CGImage)] = []
        func image(_ key: MaskKey) -> CGImage? { lock.withLock { entries.first { $0.0 == key }?.1 } }
        func insert(_ image: CGImage, _ key: MaskKey) {
            lock.withLock { entries.removeAll { $0.0 == key }; entries.append((key, image)); if entries.count > 4 { entries.removeFirst() } }
        }
    }
}

/// Shared placement in a top-left coordinate system. No image processing or allocation.
/// The sheet holds the easel opening at `margin` from its edge (or covers it, borderless); the
/// image is drawn so its `frame` fills that opening. A hand-set easel moves the picture slightly
/// off centre; it never leaves the sheet.
nonisolated struct PrintGeometry {
    /// What is printed. A clean print is masked here by the easel blades; a film-edge enlarger
    /// canvas carries its own blades (in exposure, before the paper), with the nominal opening at
    /// `frame` (unit rect of the canvas); a scan has no easel.
    enum Content: Equatable { case picture, scan, enlarger(frame: CGRect) }
    let paperSize: CGSize
    let imageRect: CGRect
    /// A clean print with a border: the picture is masked by the blades (`Easel.mask`) at this
    /// enlargement of a 36 mm frame. Zero when no blades are set.
    let magnification: Double
    /// Blade penumbra in paper pixels, for previews.
    let bladeBlur: CGFloat
    var cropsImage: Bool {
        imageRect.minX < -0.01 || imageRect.minY < -0.01
            || imageRect.maxX > paperSize.width + 0.01 || imageRect.maxY > paperSize.height + 0.01
    }

    /// The border at which the picture (its easel frame) just covers the sheet: zero when their
    /// proportions match, negative otherwise.
    static func fillMargin(imageSize: CGSize, layout: PrintLayout, content: Content = .picture) -> Double {
        guard imageSize.width > 0, imageSize.height > 0 else { return 0 }
        var frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        if case .enlarger(let unit) = content, unit.width > 0, unit.height > 0 { frame = unit }
        let fw = Double(imageSize.width * frame.width), fh = Double(imageSize.height * frame.height)
        let aspect = layout.paperAspect(imageAspect: fw / fh)
        let (w, h) = aspect >= 1 ? (1.0, 1 / aspect) : (aspect, 1.0)
        let cover = max(w / fw, h / fh)
        return min(0, min((w - cover * fw) / 2, (h - cover * fh) / 2))
    }
    init?(imageSize: CGSize, layout: PrintLayout, longEdge: CGFloat, content: Content = .picture) {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
            imageSize.width > 0, imageSize.height > 0,
            longEdge.isFinite, longEdge > 0
        else { return nil }
        var frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        if case .enlarger(let unit) = content, unit.width > 0, unit.height > 0 { frame = unit }
        let framed = CGSize(width: imageSize.width * frame.width, height: imageSize.height * frame.height)
        let m = layout.resolvedMargin(content)
        // The sheet never changes with the border: as image it keeps the picture's proportions,
        // and the border insets the picture, as on any fixed sheet.
        let aspect = layout.paperAspect(imageAspect: framed.width / framed.height)
        let size = aspect >= 1
            ? CGSize(width: longEdge, height: longEdge / aspect)
            : CGSize(width: longEdge * aspect, height: longEdge)
        // The same integer canvas drives both export and a pixel-aligned preview.
        paperSize = CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
        let long = max(paperSize.width, paperSize.height)
        let border = m * Double(long)
        let room = CGSize(width: max(1, paperSize.width - 2 * border), height: max(1, paperSize.height - 2 * border))
        let scale = layout.fill
            ? max(paperSize.width / framed.width, paperSize.height / framed.height)
            : min(room.width / framed.width, room.height / framed.height)
        var opening = CGRect(x: (paperSize.width - framed.width * scale) / 2, y: (paperSize.height - framed.height * scale) / 2,
                             width: framed.width * scale, height: framed.height * scale)
        let blades = !layout.fill && m > 0 && content != .scan
        if blades && layout.handSet {
            // Never into the paper's edge: at most 45 % of the margin on that axis.
            let shift = Easel.placement * long
            let free = CGSize(width: max(0, opening.minX), height: max(0, opening.minY))
            opening.origin.x += min(max(shift * Easel.jitter(layout.easelSeed, 1), -0.45 * free.width), 0.45 * free.width)
            opening.origin.y += min(max(shift * Easel.jitter(layout.easelSeed, 2), -0.45 * free.height), 0.45 * free.height)
        }
        imageRect = CGRect(x: opening.minX - frame.minX * imageSize.width * scale,
                           y: opening.minY - frame.minY * imageSize.height * scale,
                           width: imageSize.width * scale, height: imageSize.height * scale)
        // A 35 mm frame enlarged to the opening; a sheet without a physical size is taken as 6 inches.
        let pixelsPerMillimetre = Double(long) / (layout.paper.longMillimetres ?? 152.4)
        let enlargement = Double(max(opening.width, opening.height)) / pixelsPerMillimetre / 36
        magnification = blades && content == .picture ? enlargement : 0
        bladeBlur = magnification > 0 ? CGFloat(Easel.penumbra(magnification: enlargement) * pixelsPerMillimetre) : 0
    }
}
