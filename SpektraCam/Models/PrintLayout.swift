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
    var isIdentity: Bool { paper == .asImage && orientation == .automatic && scale == 1 }

    init() {}
    enum CodingKeys: String, CodingKey { case paper, orientation, scale }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        paper = try values.decodeIfPresent(Paper.self, forKey: .paper) ?? .asImage
        orientation = try values.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .automatic
        scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? 1
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

/// Shared, centered placement in a top-left coordinate system. No image processing or allocation.
nonisolated struct PrintGeometry {
    let paperSize: CGSize
    let imageRect: CGRect
    let fillScale: Double
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
        imageRect = CGRect(
            x: (paperSize.width - placed.width) / 2,
            y: (paperSize.height - placed.height) / 2,
            width: placed.width, height: placed.height)
    }
}
