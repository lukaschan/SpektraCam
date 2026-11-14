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
    /// Relative to fitting the whole photograph inside the fixed paper.
    var scale = 1.0
    static let scaleRange = 0.25...4.0
    /// Printed on a hand-set easel: blades set by eye leave slightly uneven margins and, on a
    /// film-edge enlarger print, a projection a fraction of a degree off square. Off is a
    /// perfectly centred machine print.
    var handSet = true
    var easelSeed: UInt32 = 1
    var isIdentity: Bool { paper == .asImage && orientation == .automatic && scale == 1 }
    /// Nothing to save: identity placement with the default easel.
    var isDefault: Bool { isIdentity && handSet && easelSeed == 1 }
    /// Only what a film-edge render needs; paper drags never re-render the film.
    var easelOnly: Self {
        var easel = Self()
        easel.handSet = handSet
        easel.easelSeed = easelSeed
        return easel
    }

    init() {}
    enum CodingKeys: String, CodingKey { case paper, orientation, scale, handSet, easelSeed }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        paper = try values.decodeIfPresent(Paper.self, forKey: .paper) ?? .asImage
        orientation = try values.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .automatic
        scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        handSet = try values.decodeIfPresent(Bool.self, forKey: .handSet) ?? true
        easelSeed = try values.decodeIfPresent(UInt32.self, forKey: .easelSeed) ?? 1
        guard scale.isFinite, Self.scaleRange.contains(scale) else {
            throw DecodingError.dataCorruptedError(
                forKey: .scale, in: values, debugDescription: "Unsupported print scale")
        }
    }
    func paperAspect(imageAspect: Double) -> Double {
        guard let ratio = paper.shortToLong else { return imageAspect }
        let landscape = orientation == .landscape
            || (orientation == .automatic && imageAspect > 1)
        return landscape ? 1 / ratio : ratio
    }
}

/// The enlarging easel. Its blades lie on the paper, a little above the emulsion at their edge, so
/// each blade casts a penumbra: the lens pupil (diameter f/N) seen from the paper at the image
/// distance f(1 + M) spans an angle 1/(N(1 + M)), so a blade edge h above the emulsion blurs over
/// h / (N(1 + M)) on the paper, plus the paper's own light spread. Typical values, not one easel.
nonisolated enum Easel {
    static let bladeHeight = 3.0, aperture = 8.0, paperSpread = 0.03
    /// Width of the blade edge's light ramp on the paper, in millimetres.
    static func penumbra(magnification m: Double) -> Double {
        bladeHeight / (aperture * (1 + max(m, 0))) + paperSpread
    }
    /// A hand-set easel lands a little off: up to this fraction of the sheet's long side.
    static let placement = 0.008
    /// Seeded unit values in [-1, 1] for a hand-set placement.
    static func jitter(_ seed: UInt32, _ k: Int32) -> Double {
        FilmEdgeNoise.unit(FilmEdgeNoise.hash(k, 77, seed)) * 2 - 1
    }
}

/// Shared placement in a top-left coordinate system. No image processing or allocation.
/// A hand-set easel moves the picture slightly off centre; it never crops it or leaves the sheet.
nonisolated struct PrintGeometry {
    let paperSize: CGSize
    let imageRect: CGRect
    let fillScale: Double
    /// Blade penumbra in paper pixels for a clean (borderless) enlarger print; zero when the
    /// paper has no physical size or the easel is not hand-set.
    let bladeBlur: CGFloat
    var cropsImage: Bool {
        imageRect.minX < -0.01 || imageRect.minY < -0.01
            || imageRect.maxX > paperSize.width + 0.01
            || imageRect.maxY > paperSize.height + 0.01
    }

    init?(imageSize: CGSize, layout: PrintLayout, longEdge: CGFloat) {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
            imageSize.width > 0, imageSize.height > 0,
            longEdge.isFinite, longEdge > 0,
            layout.scale.isFinite, PrintLayout.scaleRange.contains(layout.scale)
        else { return nil }
        let aspect = layout.paperAspect(imageAspect: imageSize.width / imageSize.height)
        let size = aspect >= 1
            ? CGSize(width: longEdge, height: longEdge / aspect)
            : CGSize(width: longEdge * aspect, height: longEdge)
        // The same integer canvas drives both export and a pixel-aligned preview.
        paperSize = CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
        let fit = min(paperSize.width / imageSize.width, paperSize.height / imageSize.height)
        let fill = max(paperSize.width / imageSize.width, paperSize.height / imageSize.height)
        fillScale = fill / fit
        let placed = CGSize(
            width: imageSize.width * fit * layout.scale,
            height: imageSize.height * fit * layout.scale)
        var rect = CGRect(
            x: (paperSize.width - placed.width) / 2,
            y: (paperSize.height - placed.height) / 2,
            width: placed.width, height: placed.height)
        var blur: CGFloat = 0
        if layout.handSet, let sheet = layout.paper.longMillimetres {
            let long = max(paperSize.width, paperSize.height)
            let shift = Easel.placement * long
            // Never into the paper's edge: at most 45 % of the margin on that axis.
            let room = CGSize(width: max(0, rect.minX), height: max(0, rect.minY))
            rect.origin.x += min(max(shift * Easel.jitter(layout.easelSeed, 1), -0.45 * room.width), 0.45 * room.width)
            rect.origin.y += min(max(shift * Easel.jitter(layout.easelSeed, 2), -0.45 * room.height), 0.45 * room.height)
            // A 35 mm frame (36 mm long) enlarged to the picture's size on this sheet.
            let pixelsPerMillimetre = Double(long) / sheet
            let magnification = Double(max(rect.width, rect.height)) / pixelsPerMillimetre / 36
            blur = CGFloat(Easel.penumbra(magnification: magnification) * pixelsPerMillimetre)
        }
        imageRect = rect
        bladeBlur = blur
    }
}
