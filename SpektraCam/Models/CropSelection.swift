import CoreGraphics
import Foundation

/// Non-destructive crop, normalized to each axis after the upright geometry transform. ED-03.
/// Origin is top-left. Upstream crop_size uses the long edge, requiring conversion.
nonisolated struct CropSelection: Codable, Equatable, Sendable {
    static let fullImage = CGRect(x: 0, y: 0, width: 1, height: 1)
    var normalizedRect = fullImage
    var aspect: CropAspect = .original
    var orientation: CropOrientation = .automatic

    func effectiveRatio(imageAspect: CGFloat) -> CGFloat? {
        guard let ratio = aspect.ratio(imageAspect: imageAspect) else { return nil }
        switch orientation {
        case .automatic: return ratio
        case .portrait: return min(ratio, 1 / ratio)
        case .landscape: return max(ratio, 1 / ratio)
        }
    }

    mutating func setOrientation(_ orientation: CropOrientation, imageAspect: CGFloat) {
        self.orientation = orientation
        setAspect(aspect == .free ? .original : aspect, imageAspect: imageAspect)
    }

    mutating func rotateLeft(imageAspect: CGFloat) {
        let old = normalizedRect
        let newAspect = old.height / (old.width * imageAspect)
        normalizedRect = CGRect(
            x: old.minY, y: 1 - old.maxX,
            width: old.height, height: old.width)
        orientation = newAspect >= 1 ? .landscape : .portrait
    }

    mutating func flipHorizontal() { normalizedRect.origin.x = 1 - normalizedRect.maxX }
    mutating func flipVertical() { normalizedRect.origin.y = 1 - normalizedRect.maxY }

    mutating func setAspect(_ aspect: CropAspect, imageAspect: CGFloat) {
        self.aspect = aspect
        guard let ratio = effectiveRatio(imageAspect: imageAspect) else { return }
        let normalizedRatio = ratio / imageAspect
        let width = min(1, normalizedRatio)
        let height = width / normalizedRatio
        normalizedRect = CGRect(
            x: clamp(normalizedRect.midX - width / 2, 0, 1 - width),
            y: clamp(normalizedRect.midY - height / 2, 0, 1 - height),
            width: width, height: height
        )
    }

    /// Trim the existing window to a required aperture without stretching or revealing
    /// previously excluded content. The interactive Crop tool uses this same selection.
    mutating func constrain(to aspect: CropAspect, orientation: CropOrientation, imageAspect: CGFloat) {
        self.aspect = aspect
        self.orientation = orientation
        guard let ratio = effectiveRatio(imageAspect: imageAspect), imageAspect > 0 else { return }
        let old = normalizedRect.intersection(Self.fullImage)
        guard !old.isNull, !old.isEmpty else { return }
        let normalizedRatio = ratio / imageAspect
        let width = min(old.width, old.height * normalizedRatio)
        let height = min(old.height, old.width / normalizedRatio)
        // Avoid accumulating floating-point trimming during a drag or repeated render.
        guard abs(width - old.width) > 1e-10 || abs(height - old.height) > 1e-10 else { return }
        normalizedRect = CGRect(x: width == old.width ? old.minX : old.midX - width / 2,
                                y: height == old.height ? old.minY : old.midY - height / 2,
                                width: width, height: height)
    }

    mutating func move(from start: CGRect, by delta: CGSize) {
        normalizedRect = CGRect(
            x: clamp(start.minX + delta.width, 0, 1 - start.width),
            y: clamp(start.minY + delta.height, 0, 1 - start.height),
            width: start.width, height: start.height
        )
    }

    mutating func resize(
        from start: CGRect, corner: CropCorner, by delta: CGSize, imageAspect: CGFloat
    ) {
        let anchor = corner.opposite.position(in: start)
        let point = corner.position(in: start)
        let signX: CGFloat = corner.isLeft ? -1 : 1
        let signY: CGFloat = corner.isTop ? -1 : 1
        let availableWidth = corner.isLeft ? anchor.x : 1 - anchor.x
        let availableHeight = corner.isTop ? anchor.y : 1 - anchor.y
        var width = signX * (point.x + delta.width - anchor.x)
        var height = signY * (point.y + delta.height - anchor.y)

        if let ratio = effectiveRatio(imageAspect: imageAspect) {
            let normalizedRatio = ratio / imageAspect
            // Project the finger delta onto the constrained corner diagonal in image pixels.
            // This avoids switching axes abruptly as the fingertip crosses the diagonal.
            let dx = signX * delta.width
            let dy = signY * delta.height
            let r = normalizedRatio
            let change =
                (dx * imageAspect * imageAspect + dy / r)
                / (imageAspect * imageAspect + 1 / (r * r))
            width = start.width + change
            let maximum = min(availableWidth, availableHeight * normalizedRatio)
            let minimum = min(maximum, min(0.08, 0.08 * normalizedRatio))
            width = clamp(width, minimum, maximum)
            height = width / normalizedRatio
        } else {
            width = clamp(width, min(0.08, availableWidth), availableWidth)
            height = clamp(height, min(0.08, availableHeight), availableHeight)
        }

        normalizedRect = CGRect(
            x: corner.isLeft ? anchor.x - width : anchor.x,
            y: corner.isTop ? anchor.y - height : anchor.y,
            width: width, height: height
        )
    }

    /// Convert image coordinates to integral pixels, never screen coordinates.
    func pixelRect(in pixelSize: CGSize) -> CGRect {
        let rect = normalizedRect.intersection(Self.fullImage)
        guard !rect.isEmpty, !rect.isNull, pixelSize.width >= 1, pixelSize.height >= 1 else {
            return .zero
        }
        let width = max(
            1, min(pixelSize.width, (rect.width * pixelSize.width).rounded(.toNearestOrEven)))
        let height = max(
            1, min(pixelSize.height, (rect.height * pixelSize.height).rounded(.toNearestOrEven)))
        return CGRect(
            x: clamp(
                (rect.minX * pixelSize.width).rounded(.toNearestOrEven), 0, pixelSize.width - width),
            y: clamp(
                (rect.minY * pixelSize.height).rounded(.toNearestOrEven), 0,
                pixelSize.height - height),
            width: width, height: height
        )
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}

nonisolated enum CropAspect: String, CaseIterable, Identifiable, Codable, Sendable {
    case free = "Free"
    case original = "Original"
    case square = "1:1"
    case fourThree = "4:3"
    case threeFour = "3:4"
    case threeTwo = "3:2"
    case twoThree = "2:3"
    case sixteenNine = "16:9"
    case nineSixteen = "9:16"
    case cinemaFlat = "1.85:1"
    case cinemaScope = "2.39:1"
    case rollSquare = "120 · 6×6 (square)"
    case super35ANSI = "Super 35 · ANSI 24.9×18.7 mm"
    case super16ARRI = "Super 16 · ARRI 12.35×7.5 mm"
    case super8Camera = "Super 8 · camera 5.79×4.01 mm"
    case seventyFivePerf = "70 mm · 5-perf presentation 2.20:1"
    case imaxFifteenPerf = "IMAX 15/70 · presentation 1.43:1"

    var id: Self { self }
    var title: String {
        switch self {
        case .free: String(localized: "crop.aspect.free", defaultValue: "Free")
        case .original: String(localized: "crop.aspect.original", defaultValue: "Original")
        case .rollSquare:
            String(localized: "crop.aspect.rollSquare", defaultValue: "120 · 6×6 (square)")
        case .super35ANSI:
            String(
                localized: "crop.aspect.super35ANSI", defaultValue: "Super 35 · ANSI 24.9×18.7 mm")
        case .super16ARRI:
            String(
                localized: "crop.aspect.super16ARRI", defaultValue: "Super 16 · ARRI 12.35×7.5 mm")
        case .super8Camera:
            String(
                localized: "crop.aspect.super8Camera", defaultValue: "Super 8 · camera 5.79×4.01 mm"
            )
        case .seventyFivePerf:
            String(
                localized: "crop.aspect.seventyFivePerf",
                defaultValue: "70 mm · 5-perf presentation 2.20:1")
        case .imaxFifteenPerf:
            String(
                localized: "crop.aspect.imaxFifteenPerf",
                defaultValue: "IMAX 15/70 · presentation 1.43:1")
        default: rawValue
        }
    }

    func ratio(imageAspect: CGFloat) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: imageAspect
        case .square: 1
        case .fourThree: 4 / 3
        case .threeFour: 3 / 4
        case .threeTwo: 3 / 2
        case .twoThree: 2 / 3
        case .sixteenNine: 16 / 9
        case .nineSixteen: 9 / 16
        case .cinemaFlat: 1.85
        case .cinemaScope: 2.39
        case .rollSquare: 1
        case .super35ANSI: 24.9 / 18.7
        case .super16ARRI: 12.35 / 7.5
        case .super8Camera: 5.79 / 4.01
        case .seventyFivePerf: 2.20
        case .imaxFifteenPerf: 1.43
        }
    }
}

nonisolated enum CropOrientation: String, CaseIterable, Codable, Sendable {
    case automatic, portrait, landscape
}

nonisolated enum CropCorner: String, CaseIterable, Identifiable, Codable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: Self { self }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var title: String {
        switch self {
        case .topLeft:
            String(
                localized: "crop_selection.top_left_crop_corner",
                defaultValue: "Top left crop corner")
        case .topRight:
            String(
                localized: "crop_selection.top_right_crop_corner",
                defaultValue: "Top right crop corner")
        case .bottomLeft:
            String(
                localized: "crop_selection.bottom_left_crop_corner",
                defaultValue: "Bottom left crop corner")
        case .bottomRight:
            String(
                localized: "crop_selection.bottom_right_crop_corner",
                defaultValue: "Bottom right crop corner")
        }
    }
    var opposite: Self {
        switch self {
        case .topLeft: .bottomRight
        case .topRight: .bottomLeft
        case .bottomLeft: .topRight
        case .bottomRight: .topLeft
        }
    }
    func position(in rect: CGRect) -> CGPoint {
        CGPoint(x: isLeft ? rect.minX : rect.maxX, y: isTop ? rect.minY : rect.maxY)
    }
}
