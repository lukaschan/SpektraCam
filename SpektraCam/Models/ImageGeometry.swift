import CoreGraphics
import Foundation

/// Applied before the normalized crop rectangle. Positive angles turn left.
nonisolated struct ImageGeometry: Codable, Equatable, Sendable {
    var quarterTurns = 0
    var straightenDegrees = 0.0
    var flippedHorizontally = false
    var flippedVertically = false
    var framingX = 0.0
    var framingY = 0.0

    var isIdentity: Bool { self == ImageGeometry() }

    /// The quarter turns and mirrors alone, as applied to an image that is already framed.
    var orientationOnly: ImageGeometry {
        ImageGeometry(
            quarterTurns: quarterTurns, flippedHorizontally: flippedHorizontally,
            flippedVertically: flippedVertically)
    }
    /// Where a point of the source lands after the quarter turns and mirrors. Unit
    /// coordinates with the origin at the top left; straightening is not represented.
    private func oriented(_ p: CGPoint) -> CGPoint {
        var q: CGPoint
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: q = CGPoint(x: p.y, y: 1 - p.x)
        case 2: q = CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 3: q = CGPoint(x: 1 - p.y, y: p.x)
        default: q = p
        }
        if flippedHorizontally { q.x = 1 - q.x }
        if flippedVertically { q.y = 1 - q.y }
        return q
    }
    private func unoriented(_ p: CGPoint) -> CGPoint {
        var q = p
        if flippedHorizontally { q.x = 1 - q.x }
        if flippedVertically { q.y = 1 - q.y }
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return CGPoint(x: 1 - q.y, y: q.x)
        case 2: return CGPoint(x: 1 - q.x, y: 1 - q.y)
        case 3: return CGPoint(x: q.y, y: 1 - q.x)
        default: return q
        }
    }
    private static func bounds(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    /// The part of the source shown by a unit rectangle of the turned and mirrored image.
    func sourceRect(forOriented rect: CGRect) -> CGRect {
        Self.bounds(
            unoriented(CGPoint(x: rect.minX, y: rect.minY)),
            unoriented(CGPoint(x: rect.maxX, y: rect.maxY)))
    }
    func orientedRect(forSource rect: CGRect) -> CGRect {
        Self.bounds(
            oriented(CGPoint(x: rect.minX, y: rect.minY)),
            oriented(CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    mutating func rotateLeft() {
        quarterTurns = (quarterTurns + 1) % 4
        swap(&flippedHorizontally, &flippedVertically)
        let previousX = framingX
        framingX = framingY
        framingY = -previousX
    }

    mutating func flipHorizontal() {
        flippedHorizontally.toggle()
        framingX = -framingX
        straightenDegrees = -straightenDegrees
    }

    mutating func flipVertical() {
        flippedVertically.toggle()
        framingY = -framingY
        straightenDegrees = -straightenDegrees
    }

    /// Zoom needed to keep all output corners inside the rotated source.
    /// This preserves the frame's original aspect and avoids transparent borders.
    func constrainedScale(in size: CGSize) -> CGFloat {
        guard straightenDegrees != 0 else { return 1 }
        let angle = abs(straightenDegrees) * .pi / 180
        let c = cos(angle)
        let s = sin(angle)
        let required = max(c + size.height / size.width * s, c + size.width / size.height * s)
        return required + 2 / min(size.width, size.height)
    }
    /// Clamp translation in the source's rotated axes. Panning never changes scale.
    func boundedFraming(in size: CGSize) -> CGPoint {
        guard straightenDegrees != 0, size.width > 0, size.height > 0 else { return .zero }
        let angle = straightenDegrees * .pi / 180
        let c = cos(angle), s = sin(angle)
        let zoom = constrainedScale(in: size)
        let marginX = max(0, (zoom * size.width - abs(c) * size.width - abs(s) * size.height) / 2)
        let marginY = max(0, (zoom * size.height - abs(s) * size.width - abs(c) * size.height) / 2)
        let tx = framingX * size.width, ty = -framingY * size.height
        let u = min(max(c * tx + s * ty, -marginX), marginX)
        let v = min(max(-s * tx + c * ty, -marginY), marginY)
        return CGPoint(x: (c * u - s * v) / size.width, y: -(s * u + c * v) / size.height)
    }

}

extension ImageGeometry {
    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        quarterTurns = try values.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0
        straightenDegrees = try values.decodeIfPresent(Double.self, forKey: .straightenDegrees) ?? 0
        flippedHorizontally = try values.decodeIfPresent(Bool.self, forKey: .flippedHorizontally) ?? false
        flippedVertically = try values.decodeIfPresent(Bool.self, forKey: .flippedVertically) ?? false
        framingX = try values.decodeIfPresent(Double.self, forKey: .framingX) ?? 0
        framingY = try values.decodeIfPresent(Double.self, forKey: .framingY) ?? 0
    }
}
