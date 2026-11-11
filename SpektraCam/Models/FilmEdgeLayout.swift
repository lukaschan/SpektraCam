import CoreGraphics
import Foundation

/// A saved capture-support presentation. Nil in EditRecipe means Clean print.
nonisolated struct FilmEdgeLayout: Codable, Equatable, Sendable {
    enum Format: String, Codable, CaseIterable, Sendable { case film35, roll120 }
    var format = Format.film35
    var distress = FilmEdgeDistress()
    var gateSize: CGSize { format == .film35 ? CGSize(width: 36, height: 24) : CGSize(width: 56, height: 56) }
    var cropAspect: CropAspect { format == .film35 ? .threeTwo : .rollSquare }
    func gateTitle(portrait: Bool) -> String {
        if format == .roll120 { return "56 × 56 mm · 1:1" }
        return portrait ? "24 × 36 mm · 2:3" : "36 × 24 mm · 3:2"
    }
    func constrainedCrop(_ crop: CropSelection, imageSize: CGSize) -> CropSelection {
        guard imageSize.width > 0, imageSize.height > 0 else { return crop }
        var result = crop
        let current = crop.normalizedRect
        let portrait = format == .film35 && current.width * imageSize.width < current.height * imageSize.height
        result.constrain(to: cropAspect, orientation: portrait ? .portrait : .landscape,
                         imageAspect: imageSize.width / imageSize.height)
        return result
    }
    /// Integral source pixels may differ by at most one rounded pixel from the exact gate.
    func matchesGate(_ imageSize: CGSize) -> Bool {
        guard imageSize.width > 0, imageSize.height > 0 else { return false }
        let ratio = gateSize.width / gateSize.height
        return abs(max(imageSize.width, imageSize.height) - min(imageSize.width, imageSize.height) * ratio) <= ratio
    }
    init() {}
    enum CodingKeys: String, CodingKey { case format, distress }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decodeIfPresent(Format.self, forKey: .format) ?? .film35
        distress = try values.decodeIfPresent(FilmEdgeDistress.self, forKey: .distress) ?? FilmEdgeDistress()
    }
}

/// Procedural, seeded imperfections in physical film millimetres. Every field is placed at
/// the stage where its mechanism acts (see Research/Darkroom-v0.3/DISTRESS-AND-LEAKS.md):
/// camera gate, leaks and perforation fog are exposure before development; scratches thin the
/// developed dye or scatter light; dust, tape and the carrier act where the film is printed or
/// scanned. `amount` scales only intensities, so beginners can dial a preset while geeks edit
/// fields. These ranges are engineering choices, not calibrated measurements.
nonisolated struct FilmEdgeDistress: Codable, Equatable, Sendable {
    static let algorithmRevision = 2
    /// Through the lens (front) light is gated with the scene and reaches the top, blue-sensitive
    /// layer first; a back/door-seal leak bypasses the gate and enters through the base.
    enum LeakKind: String, Codable, CaseIterable, Sendable { case back, front }
    enum LeakShape: String, Codable, CaseIterable, Sendable { case glow, streak, flare }
    var revision = Self.algorithmRevision
    var seed: UInt32 = 1
    var amount = 1.0
    /// Gate-to-emulsion penumbra radius (≈ gap / 2N). Physics, not damage: on by default.
    var gateSoftness = 0.02
    var gateWear = 0.0
    var tilt = 0.0
    /// Sprocket teeth strain the hole edges; light through the holes of the outer wrap fogs the next.
    var perforationWear = 0.0
    var perforationLeak = 0.0
    var carrierRoughness = 0.0
    var carrierScale = 1.2
    /// Unmasked enlarger light reflected by a bare-metal carrier edge onto the paper (prints only).
    var carrierReflection = 0.0
    var tape = 0.0
    var tapeAge = 0.4
    var edgeFog = 0.0
    var fogDepth = 2.0
    var leak = 0.0
    var leakKind = LeakKind.back
    var leakShape = LeakShape.glow
    var leakSize = 8.0
    var leakPosition = 0.3
    /// −1 cool (front, blue layer first) … 0 neutral … +1 warm (base, red layer first).
    var warmth = 0.6
    var dust = 0.0
    var scratches = 0.0
    /// Rails and sprockets touch only the rebate, so scratches stay there by default.
    /// Releasing the clamp lets gate debris drag scratches across the picture as well.
    var scratchesInImage = false

    static let ranges: [WritableKeyPath<Self, Double>: ClosedRange<Double>] = [
        \.amount: 0...2, \.gateSoftness: 0...0.12, \.gateWear: 0...0.12, \.tilt: -1...1,
        \.perforationWear: 0...1, \.perforationLeak: 0...1,
        \.carrierRoughness: 0...0.5, \.carrierScale: 0.2...4, \.carrierReflection: 0...1,
        \.tape: 0...1, \.tapeAge: 0...1, \.edgeFog: 0...1, \.fogDepth: 0.3...8,
        \.leak: 0...1, \.leakSize: 2...30, \.leakPosition: 0...1, \.warmth: -1...1,
        \.dust: 0...1, \.scratches: 0...1,
    ]
    static func defaultWarmth(_ kind: LeakKind) -> Double { kind == .front ? -0.4 : 0.6 }

    enum Preset: String, CaseIterable, Sendable {
        case clean, lab, filed, handPrint, worn, leaky
        var title: String {
            switch self {
            case .clean: String(localized: "darkroom.distress.clean", defaultValue: "Clean")
            case .lab: String(localized: "darkroom.distress.lab", defaultValue: "Lab scan")
            case .filed: String(localized: "darkroom.distress.filed", defaultValue: "Filed carrier")
            case .handPrint: String(localized: "darkroom.distress.hand_print", defaultValue: "Hand print")
            case .worn: String(localized: "darkroom.distress.worn", defaultValue: "Old camera")
            case .leaky: String(localized: "darkroom.distress.leaky", defaultValue: "Light leak")
            }
        }
        var values: FilmEdgeDistress {
            var d = FilmEdgeDistress()
            switch self {
            case .clean: break
            case .lab:
                d.gateWear = 0.012; d.tilt = 0.12; d.carrierRoughness = 0.04; d.perforationWear = 0.15
                d.edgeFog = 0.08; d.fogDepth = 1.5; d.dust = 0.18; d.scratches = 0.06
            case .filed:
                d.gateWear = 0.02; d.tilt = 0.08; d.carrierRoughness = 0.22; d.carrierScale = 1.8
                d.perforationWear = 0.2; d.dust = 0.12; d.scratches = 0.04
            case .handPrint:
                d.gateWear = 0.015; d.tilt = 0.18; d.carrierRoughness = 0.06; d.carrierReflection = 0.45
                d.tape = 0.6; d.tapeAge = 0.5; d.perforationWear = 0.2; d.dust = 0.22; d.scratches = 0.08
            case .worn:
                d.gateSoftness = 0.035; d.gateWear = 0.05; d.tilt = 0.3; d.carrierRoughness = 0.08
                d.perforationWear = 0.5; d.perforationLeak = 0.25
                d.edgeFog = 0.3; d.fogDepth = 3; d.leak = 0.3; d.leakSize = 10; d.warmth = 0.7
                d.dust = 0.4; d.scratches = 0.35
            case .leaky:
                d.gateWear = 0.015; d.tilt = 0.1; d.edgeFog = 0.35; d.fogDepth = 4.5; d.perforationLeak = 0.35
                d.leak = 0.5; d.leakShape = .flare; d.leakSize = 14; d.warmth = 0.8; d.dust = 0.1
            }
            return d
        }
    }
    /// Seed, amount, leak position and the scratch clamp are personal choices, not part of a preset.
    var preset: Preset? {
        Preset.allCases.first { $0.values.comparable == comparable }
    }
    private var comparable: Self {
        var copy = self
        copy.seed = 1; copy.amount = 1; copy.leakPosition = 0.3; copy.scratchesInImage = false
        copy.revision = Self.algorithmRevision
        return copy
    }
    mutating func apply(_ preset: Preset) {
        let keep = (seed, amount, leakPosition, scratchesInImage)
        self = preset.values
        (seed, amount, leakPosition, scratchesInImage) = keep
    }
    /// Intensities after the global Amount. Sizes, softness, depth and colour are unchanged.
    var effective: Self {
        var e = self
        let a = max(0, amount)
        e.gateWear *= a; e.tilt *= a; e.carrierRoughness *= a
        e.perforationWear = min(1, perforationWear * a); e.perforationLeak = min(1, perforationLeak * a)
        e.carrierReflection = min(1, carrierReflection * a); e.tape = min(1, tape * a)
        e.edgeFog = min(1, edgeFog * a); e.leak = min(1, leak * a)
        e.dust = min(1, dust * a); e.scratches = min(1, scratches * a)
        return e
    }

    init() {}
    enum CodingKeys: String, CodingKey {
        case revision, seed, amount, gateSoftness, gateWear, tilt, perforationWear, perforationLeak,
            carrierRoughness, carrierScale, carrierReflection, tape, tapeAge,
            edgeFog, fogDepth, leak, leakKind, leakShape, leakSize, leakPosition, warmth, dust, scratches, scratchesInImage
    }
    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self()
        func n(_ key: CodingKeys, _ path: WritableKeyPath<Self, Double>) throws -> Double {
            let value = try v.decodeIfPresent(Double.self, forKey: key) ?? base[keyPath: path]
            guard value.isFinite else { return base[keyPath: path] }
            let range = Self.ranges[path] ?? (-Double.infinity...Double.infinity)
            return min(max(value, range.lowerBound), range.upperBound)
        }
        revision = try v.decodeIfPresent(Int.self, forKey: .revision) ?? Self.algorithmRevision
        seed = try v.decodeIfPresent(UInt32.self, forKey: .seed) ?? 1
        amount = try n(.amount, \.amount)
        gateSoftness = try n(.gateSoftness, \.gateSoftness)
        gateWear = try n(.gateWear, \.gateWear)
        tilt = try n(.tilt, \.tilt)
        perforationWear = try n(.perforationWear, \.perforationWear)
        perforationLeak = try n(.perforationLeak, \.perforationLeak)
        carrierRoughness = try n(.carrierRoughness, \.carrierRoughness)
        carrierScale = try n(.carrierScale, \.carrierScale)
        carrierReflection = try n(.carrierReflection, \.carrierReflection)
        tape = try n(.tape, \.tape)
        tapeAge = try n(.tapeAge, \.tapeAge)
        edgeFog = try n(.edgeFog, \.edgeFog)
        fogDepth = try n(.fogDepth, \.fogDepth)
        leak = try n(.leak, \.leak)
        leakKind = (try? v.decodeIfPresent(LeakKind.self, forKey: .leakKind)) ?? .back
        leakShape = (try? v.decodeIfPresent(LeakShape.self, forKey: .leakShape)) ?? .glow
        leakSize = try n(.leakSize, \.leakSize)
        leakPosition = try n(.leakPosition, \.leakPosition)
        warmth = try n(.warmth, \.warmth)
        dust = try n(.dust, \.dust)
        scratches = try n(.scratches, \.scratches)
        scratchesInImage = try v.decodeIfPresent(Bool.self, forKey: .scratchesInImage) ?? false
    }
}

/// Integer hashing and value noise shared bit-for-bit with FilmPipeline.metalSource.
nonisolated enum FilmEdgeNoise {
    static func hash(_ value: UInt32) -> UInt32 {
        var x = value
        x ^= x >> 16; x = x &* 0x7feb352d
        x ^= x >> 15; x = x &* 0x846ca68b
        x ^= x >> 16
        return x
    }
    static func hash(_ i: Int32, _ j: Int32, _ seed: UInt32) -> UInt32 {
        hash((UInt32(bitPattern: i) &* 0x8da6b343) ^ hash((UInt32(bitPattern: j) &* 0xd8163841) ^ seed))
    }
    static func unit(_ h: UInt32) -> Double { Double(h >> 8) / 16_777_216 }
    /// C¹ value noise in [-1, 1]; continuous across lattice cells, so float/double floor
    /// disagreements on a boundary cannot create a visible seam.
    static func value(_ x: Double, _ y: Double, _ seed: UInt32) -> Double {
        let fx = floor(x), fy = floor(y)
        let tx = x - fx, ty = y - fy
        let ux = tx * tx * (3 - 2 * tx), uy = ty * ty * (3 - 2 * ty)
        let ix = Int32(clamping: Int(fx)), iy = Int32(clamping: Int(fy))
        let a = unit(hash(ix, iy, seed)), b = unit(hash(ix &+ 1, iy, seed))
        let c = unit(hash(ix, iy &+ 1, seed)), d = unit(hash(ix &+ 1, iy &+ 1, seed))
        return ((a + (b - a) * ux) * (1 - uy) + (c + (d - c) * ux) * uy) * 2 - 1
    }
    /// Fraction of a disc of radius r inside a straight edge at signed distance d (d > 0 outside).
    /// Unlike a Gaussian, a geometric penumbra has no tails.
    static func penumbra(_ d: Double, _ r: Double) -> Double {
        let u = min(max(d / max(r, 1e-9), -1), 1)
        return 0.5 - (asin(u) + u * (1 - u * u).squareRoot()) / .pi
    }
    static func box(_ px: Double, _ py: Double, _ hx: Double, _ hy: Double, _ r: Double) -> Double {
        let qx = abs(px) - (hx - r), qy = abs(py) - (hy - r)
        return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
    }
}

/// One clean carrier opening. Coordinates are top-left pixels; stock geometry is in mm.
/// KS-1870: SMPTE ST 139:2003, Fig. 1/Table 1. E is an OUTER-edge gap, not a center inset.
/// The physical gate never adapts to an arbitrary photo ratio. Callers must crop first.
nonisolated struct FilmEdgeGeometry: Sendable {
    let width: Int, height: Int
    let gate: CGRect
    let format: FilmEdgeLayout.Format
    let portrait: Bool
    let millimetersPerPixel: Double
    let distress: FilmEdgeDistress
    /// Seeded, resolution-independent features, computed once per geometry.
    let leakFrame: LeakFrame
    let scratchCandidates: [Scratch]
    let tapePieces: [TapePiece]
    static let stockWidth = 34.975
    static let holeAcross = 2.794, holeAlong = 1.981, holeRadius = 0.51
    static let holePitch = 4.750, holeOuterGap = 2.01
    static let holeCenter = stockWidth / 2 - holeOuterGap - holeAcross / 2

    /// Kodak, *Essential Reference Guide for Filmmakers*, printed p. 96; SMPTE ST 93 / ST 139.
    /// KS-1870: still film and print film, rounded rectangle C 2.794 × D 1.981, R 0.51, pitch 4.750.
    /// BH-1866: cine camera negative, a C = 2.794 mm circle cut by flat edges D = 1.854 apart
    /// (sharp corners, calculated H 2.08), short pitch 4.740. C is the same, so the outer-edge gap
    /// E = 2.01 puts both hole centres at the same distance from the stock edge.
    enum Perforation: Int, Sendable {
        case ks1870 = 0, bh1866 = 1
        var pitch: Double { self == .ks1870 ? 4.750 : 4.740 }
        var halfAlong: Double { self == .ks1870 ? 1.981 / 2 : 1.854 / 2 }
        var halfAcross: Double { 2.794 / 2 }
        /// Motion-picture camera negatives keep BH holes when respooled for still cameras.
        static func source(filmID: String) -> Self { filmID.hasPrefix("kodak_vision3") ? .bh1866 : .ks1870 }
        /// Hole index, position relative to the nearest hole centre (`local` along, `t` across,
        /// signed away from the picture) and signed distance (> 0 in intact film).
        struct Hole { let index: Int32; let side: Int32; let local: Double; let t: Double; let distance: Double }
        func hole(along: Double, across: Double) -> Hole {
            let k = floor(along / pitch)
            let local = along - (k + 0.5) * pitch
            let t = abs(across) - FilmEdgeGeometry.holeCenter
            return Hole(index: Int32(clamping: Int(k)), side: across < 0 ? -1 : 1, local: local, t: t,
                        distance: distance(local: local, t: t))
        }
        func distance(local: Double, t: Double) -> Double {
            switch self {
            case .ks1870:
                let r = FilmEdgeGeometry.holeRadius
                let qx = abs(local) - (halfAlong - r), qy = abs(t) - (halfAcross - r)
                return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
            case .bh1866:
                return max(abs(local) - halfAlong, hypot(local, t) - halfAcross)
            }
        }
        func isFilm(along: Double, across: Double) -> Bool { hole(along: along, across: across).distance >= 0 }
    }
    /// The source film's holes; a cinema print's own holes are always KS-1870.
    let perforation: Perforation
    /// Provisional rounded gate corner; replace with measurements of real camera strips.
    static let gateCorner = 0.15
    static let rollStockWidth = 61.0
    static let scratchCount = 8

    /// What a transmission node does. Damage is source-film material; the carrier masks light
    /// where printing or scanning happens; the endpoint keeps clear openings black on paper.
    struct Transmission: OptionSet, Sendable {
        let rawValue: Int
        static let damage = Self(rawValue: 1)
        static let carrier = Self(rawValue: 2)
        static let endpoint = Self(rawValue: 4)
        static let destination = Self(rawValue: 8)
        /// Paper printing only: carrier-edge reflection of unmasked enlarger light.
        static let reflection = Self(rawValue: 16)
    }

    init?(imageSize: CGSize, layout: FilmEdgeLayout, longEdge: Int, perforation: Perforation = .ks1870) {
        guard imageSize.width > 0, imageSize.height > 0,
              imageSize.width.isFinite, imageSize.height.isFinite,
              longEdge > 0, longEdge <= 65_536, layout.matchesGate(imageSize) else { return nil }
        format = layout.format
        self.perforation = perforation
        distress = layout.distress.effective
        portrait = imageSize.height > imageSize.width
        let short = layout.gateSize.height
        let long = layout.gateSize.width
        let alongReveal = 0.8
        let acrossReveal = format == .film35 ? 1.2 : 0.8
        let extent = CGSize(width: long + 2 * alongReveal, height: short + 2 * acrossReveal)
        let factor = Double(longEdge) / max(extent.width, extent.height)
        let landscapeSize = CGSize(width: max(1, (extent.width * factor).rounded()),
                                   height: max(1, (extent.height * factor).rounded()))
        width = Int(portrait ? landscapeSize.height : landscapeSize.width)
        height = Int(portrait ? landscapeSize.width : landscapeSize.height)
        // A single uniform pitch avoids stretching the holes when the canvas is rounded.
        millimetersPerPixel = 1 / factor
        let size = CGSize(width: (portrait ? short : long) * factor,
                          height: (portrait ? long : short) * factor)
        gate = CGRect(x: (Double(width) - size.width) / 2, y: (Double(height) - size.height) / 2,
                      width: size.width, height: size.height)
        let ha = Double(portrait ? height : width) / factor / 2
        let ht = Double(portrait ? width : height) / factor / 2
        leakFrame = Self.leakFrame(distress, portrait: portrait, halfAlong: ha, halfAcross: ht)
        scratchCandidates = Self.scratches(distress, halfAlong: ha, halfAcross: ht, gateAcross: short / 2)
        tapePieces = Self.tapePieces(distress, halfAlong: ha, halfAcross: ht, gateAcross: short / 2)
    }

    var pixelPitchMicrometers: Double { millimetersPerPixel * 1000 }
    private var tiltRadians: Double { distress.tilt * .pi / 180 }
    private var stockHalf: Double { (format == .film35 ? Self.stockWidth : Self.rollStockWidth) / 2 }
    /// Canvas millimetres from the centre, in canvas x/y (y down).
    private func canvas(_ x: Double, _ y: Double) -> (Double, Double) {
        ((x - Double(width) / 2) * millimetersPerPixel, (y - Double(height) / 2) * millimetersPerPixel)
    }
    /// Film millimetres in canvas x/y: the strip turns by `tilt` inside the fixed carrier.
    func film(_ x: Double, _ y: Double) -> (Double, Double) {
        let (cx, cy) = canvas(x, y)
        let c = cos(tiltRadians), s = sin(tiltRadians)
        return (c * cx + s * cy, -s * cx + c * cy)
    }
    /// Transport (`along`) and stock-width (`across`) axes. Portrait is a rotation, not a mirror.
    private func strip(_ fx: Double, _ fy: Double) -> (along: Double, across: Double) {
        portrait ? (fy, -fx) : (fx, fy)
    }
    private var gateHalf: (Double, Double) { (gate.width * millimetersPerPixel / 2, gate.height * millimetersPerPixel / 2) }
    private var pixelRadius: Double { 0.56 * millimetersPerPixel }
    private func seed(_ stream: UInt32) -> UInt32 { Self.streamSeed(distress.seed, stream) }

    /// Camera-gate exposure coverage: penumbra, pixel area and seeded wear of the aperture edge.
    func gateCoverage(x: Int, y: Int) -> Double {
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        let (hx, hy) = gateHalf
        let base = FilmEdgeNoise.box(fx, fy, hx, hy, Self.gateCorner)
        let r = (distress.gateSoftness * distress.gateSoftness + pixelRadius * pixelRadius).squareRoot()
        let wear = distress.gateWear
        if base < -(r + wear) { return 1 }
        if base > r + wear { return 0 }
        var d = base
        if wear > 0 {
            let (a, t) = strip(fx, fy)
            let broad = FilmEdgeNoise.value(a / 0.9, t / 0.9, seed(1))
            let fine = FilmEdgeNoise.value(a / 0.16, t / 0.16, seed(2))
            d += wear * (0.65 * broad + 0.35 * fine)
        }
        return FilmEdgeNoise.penumbra(d, r)
    }

    /// Unwanted exposure, relative to a mid-grey scene exposure. `front` light comes through the
    /// lens and is gated with the scene; `back` (door/seal) light bypasses the gate; `fog` is
    /// base-path light: edge piping from the long film edges and perforation-shaped fog where
    /// light shone through the holes of the outer wrap onto the next one.
    struct Exposure: Sendable { var front = 0.0, back = 0.0, fog = 0.0 }
    func exposureFields(x: Int, y: Int) -> Exposure {
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        let (a, t) = strip(fx, fy)
        var e = Exposure()
        if distress.edgeFog > 0 {
            let distance = max(0, stockHalf - abs(t))
            let n = FilmEdgeNoise.value(a / 6, t > 0 ? 3.5 : -3.5, seed(3))
            e.fog += 6 * distress.edgeFog * distress.edgeFog * exp(-distance / distress.fogDepth) * (0.6 + 0.4 * n)
        }
        if distress.perforationLeak > 0 && format == .film35 { e.fog += perforationFog(a, t) }
        if distress.leak > 0 {
            let value = 6 * distress.leak * distress.leak * leakField(fx, fy)
            if distress.leakKind == .front { e.front = value } else { e.back = value }
        }
        return e
    }
    private func leakField(_ fx: Double, _ fy: Double) -> Double {
        let leak = leakFrame, size = distress.leakSize
        let vx = fx - leak.point.0, vy = fy - leak.point.1
        let depth = max(0, vx * leak.normal.0 + vy * leak.normal.1)
        let lateral = vx * leak.normal.1 - vy * leak.normal.0
        let n = FilmEdgeNoise.value(fx / (0.6 * size), fy / (0.6 * size), seed(4))
        switch distress.leakShape {
        case .glow:
            let lobeA = exp(-lateral * lateral / (2 * pow(1.4 * size, 2)))
            let shifted = lateral - leak.offset * size
            let lobeB = exp(-shifted * shifted / (2 * pow(0.7 * size, 2)))
            return exp(-depth / size) * (lobeA + leak.weight * lobeB) * (0.75 + 0.25 * n)
        case .streak:
            let along = max(0, vx * leak.direction.0 + vy * leak.direction.1)
            let across = vx * leak.direction.1 - vy * leak.direction.0
            let core = exp(-across * across / (2 * pow(0.22 * size, 2)))
            let shifted = across - leak.offset * 0.9 * size
            let echo = leak.weight * 0.5 * exp(-shifted * shifted / (2 * pow(0.12 * size, 2)))
            return exp(-along / (3.5 * size)) * (core + echo) * (0.7 + 0.3 * n)
        case .flare:
            let broad = exp(-lateral * lateral / (2 * pow(3 * size, 2)))
            let band = 0.8 + 0.2 * FilmEdgeNoise.value(lateral / (1.5 * size), 0.5, seed(4))
            return exp(-depth / (2.2 * size)) * broad * band
        }
    }
    /// Light through a hole of the wrap above: a softened image of the hole, displaced toward the
    /// picture, on a seeded subset of holes. Very small exposures; through the base (warm).
    private func perforationFog(_ a: Double, _ t: Double) -> Double {
        let p = perforation, side: Int32 = t < 0 ? -1 : 1
        let k0 = Int32(clamping: Int(floor(a / p.pitch)))
        let s = seed(41)
        var total = 0.0
        for dk in Int32(-1)...1 {
            let k = k0 &+ dk
            let h0 = FilmEdgeNoise.hash(k, side, s)
            let active = min(max((distress.perforationLeak * 0.85 - FilmEdgeNoise.unit(h0)) / 0.12, 0), 1)
            if active <= 0 { continue }
            let h1 = FilmEdgeNoise.hash(h0), h2 = FilmEdgeNoise.hash(h1), h3 = FilmEdgeNoise.hash(h2), h4 = FilmEdgeNoise.hash(h3)
            let centerA = (Double(k) + 0.5) * p.pitch + (FilmEdgeNoise.unit(h1) - 0.5) * 0.6 * p.pitch
            let inward = 0.3 + 1.2 * FilmEdgeNoise.unit(h2)
            let local = a - centerA, tt = abs(t) - (Self.holeCenter - inward)
            let soft = 0.12 + 0.35 * FilmEdgeNoise.unit(h3)
            // Sharp toward the light, softer away from it: widen the penumbra on the picture side.
            let r = soft * (tt < 0 ? 1.8 : 1)
            total += active * (0.4 + 0.6 * FilmEdgeNoise.unit(h4)) * FilmEdgeNoise.penumbra(p.distance(local: local, t: tt), r)
        }
        return 1.5 * distress.perforationLeak * distress.perforationLeak * total
    }

    struct LeakFrame: Sendable { let point: (Double, Double), normal: (Double, Double), offset: Double, weight: Double; let direction: (Double, Double) }
    /// The leak's entry point walks around the strip's perimeter; normal points into the film.
    static func leakFrame(_ d: FilmEdgeDistress, portrait: Bool, halfAlong ha: Double, halfAcross ht: Double) -> LeakFrame {
        let perimeter = 4 * (ha + ht)
        var s = (d.leakPosition - floor(d.leakPosition)) * perimeter
        var a = 0.0, t = 0.0, na = 0.0, nt = 0.0
        if s < 2 * ha { a = -ha + s; t = -ht; nt = 1 } else {
            s -= 2 * ha
            if s < 2 * ht { a = ha; t = -ht + s; na = -1 } else {
                s -= 2 * ht
                if s < 2 * ha { a = ha - s; t = ht; nt = -1 } else { s -= 2 * ha; a = -ha; t = ht - s; na = 1 }
            }
        }
        // Back to canvas x/y (inverse of `strip`).
        let point = portrait ? (-t, a) : (a, t)
        let normal = portrait ? (-nt, na) : (na, nt)
        let h = streamSeed(d.seed, 5), h2 = FilmEdgeNoise.hash(h), h3 = FilmEdgeNoise.hash(h2)
        // A streak leaves the entry edge up to ±35° from square to it.
        let turn = (FilmEdgeNoise.unit(h3) * 2 - 1) * 0.61
        let direction = (normal.0 * cos(turn) - normal.1 * sin(turn), normal.0 * sin(turn) + normal.1 * cos(turn))
        return LeakFrame(point: point, normal: normal, offset: FilmEdgeNoise.unit(h) * 1.6 - 0.8,
                         weight: 0.35 + 0.4 * FilmEdgeNoise.unit(h2), direction: direction)
    }
    static func streamSeed(_ seed: UInt32, _ stream: UInt32) -> UInt32 { FilmEdgeNoise.hash(seed ^ (stream &* 0x9e3779b9)) }

    /// Exact supersampled perforation coverage: 1 is intact film, 0 a clear opening.
    func supportCoverage(x: Int, y: Int, destination: Bool = false) -> Double {
        guard format == .film35 else { return 1 }
        let kind = destination ? Perforation.ks1870 : perforation
        let wear = destination ? 0 : distress.perforationWear
        var covered = 0.0
        for sy in 0..<4 { for sx in 0..<4 {
            let (fx, fy) = film(Double(x) + (Double(sx) + 0.5) / 4, Double(y) + (Double(sy) + 0.5) / 4)
            let (along, across) = strip(fx, fy)
            // Centered frame; phase is fixed, with no random shuffling.
            var hole = kind.hole(along: along, across: across)
            if wear > 0 && abs(hole.distance) < 0.2 { hole = worn(hole, kind) }
            if hole.distance >= 0 { covered += 1 }
        }}
        return covered / 16
    }
    /// Punched edges are not perfect: fine per-hole roughness, and on a strained hole a small tear
    /// on the side the sprocket teeth pull (+along). Hole size is otherwise the nominal standard.
    private func worn(_ hole: Perforation.Hole, _ kind: Perforation) -> Perforation.Hole {
        let wear = distress.perforationWear, s = seed(40)
        let h0 = FilmEdgeNoise.hash(hole.index, hole.side, s)
        let rough = (0.004 + 0.016 * wear * (0.4 + 0.6 * FilmEdgeNoise.unit(h0)))
            * FilmEdgeNoise.value(hole.local / 0.045 + Double(hole.index) * 3.7, hole.t / 0.045 + Double(hole.side) * 11.1, s)
        var tear = 0.0
        let h1 = FilmEdgeNoise.hash(h0)
        if FilmEdgeNoise.unit(h1) < wear * 0.7 {
            let h2 = FilmEdgeNoise.hash(h1), h3 = FilmEdgeNoise.hash(h2)
            let t0 = (FilmEdgeNoise.unit(h2) * 2 - 1) * 0.75 * kind.halfAcross
            let width = 0.12 + 0.22 * FilmEdgeNoise.unit(h3), depth = (0.025 + 0.07 * FilmEdgeNoise.unit(h3)) * wear
            let leading = pow(min(max(hole.local / kind.halfAlong, 0), 1), 4)
            tear = depth * leading * exp(-pow((hole.t - t0) / width, 2))
        }
        return Perforation.Hole(index: hole.index, side: hole.side, local: hole.local, t: hole.t,
                                distance: hole.distance + rough - tear)
    }
    /// The punched wall scatters a little light just outside each hole (a faint, patchy shoulder).
    func perforationShoulder(x: Int, y: Int) -> Double {
        let wear = distress.perforationWear
        guard wear > 0, format == .film35 else { return 0 }
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        let (along, across) = strip(fx, fy)
        let hole = perforation.hole(along: along, across: across)
        guard hole.distance > -0.01, hole.distance < 0.15 else { return 0 }
        let patch = 0.6 + 0.4 * FilmEdgeNoise.value(hole.local / 0.3, hole.t / 0.3 + Double(hole.index), seed(42))
        return (0.03 + 0.1 * wear) * exp(-max(hole.distance, 0) / 0.035) * patch
    }

    /// Signed distance to the filed carrier opening (> 0 where the carrier blocks light), fixed to
    /// the canvas: the film can tilt inside it.
    func carrierDistance(x: Int, y: Int) -> Double {
        let (cx, cy) = canvas(Double(x) + 0.5, Double(y) + 0.5)
        let hx = Double(width) * millimetersPerPixel / 2, hy = Double(height) * millimetersPerPixel / 2
        let base = FilmEdgeNoise.box(cx, cy, hx, hy, 0)
        let amplitude = distress.carrierRoughness
        guard amplitude > 0, base > -(amplitude * 1.6 + pixelRadius) else { return base }
        let (a, t) = strip(cx, cy)
        let scale = distress.carrierScale
        // Mostly smooth filing with a little file-tooth texture and a few sparse nicks.
        let broad = 0.5 + 0.5 * (0.85 * FilmEdgeNoise.value(a / scale, t / scale, seed(6))
            + 0.15 * FilmEdgeNoise.value(a / (0.2 * scale), t / (0.2 * scale), seed(7)))
        let n = FilmEdgeNoise.value(a / (0.35 * scale), t / (0.35 * scale), seed(8))
        let notch = min(max((n - 0.6) / 0.3, 0), 1)
        return base + amplitude * (broad + 0.5 * notch * notch * (3 - 2 * notch))
    }
    func carrierCoverage(x: Int, y: Int) -> Double {
        guard distress.carrierRoughness > 0 else { return 1 }
        return FilmEdgeNoise.penumbra(carrierDistance(x: x, y: y), pixelRadius)
    }
    /// Enlarger light glancing off a bare-metal carrier edge lands just inside the opening without
    /// passing through the negative's mask, so on RA-4 it prints as a darker, coloured band.
    func carrierReflection(x: Int, y: Int) -> Double {
        let r = distress.carrierReflection
        guard r > 0 else { return 0 }
        let d = carrierDistance(x: x, y: y)
        guard d < 0 else { return 0 }
        let (cx, cy) = canvas(Double(x) + 0.5, Double(y) + 0.5)
        let (a, t) = strip(cx, cy)
        let n = FilmEdgeNoise.value(a / 4, t / 4, seed(43))
        return 0.4 * r * exp(d / 0.45) * (0.7 + 0.3 * n)
    }
    /// Tape holding the strip in its holder: up to two pieces along the long edges, fixed to the
    /// film. Frosted tape passes ~85 %; ageing yellows it (absorbs blue). Per-channel transmission.
    func tapeTransmission(x: Int, y: Int) -> SIMD3<Double> {
        let amount = distress.tape
        guard amount > 0 else { return .one }
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        let (a, t) = strip(fx, fy)
        var cover = 0.0
        for piece in tapePieces {
            let opacity = min(max(amount * 2 - piece.order, 0), 1)
            if opacity <= 0 || (t < 0) != (piece.side < 0) { continue }
            let wobble = 0.03 * FilmEdgeNoise.value(a / 1.5, piece.side * 5, seed(44))
            let edge = piece.inner - abs(t) + wobble          // > 0 outside the tape
            let ends = max(piece.start - a + 0.08 * t, a - piece.end - 0.06 * t)
            cover = max(cover, opacity * FilmEdgeNoise.penumbra(max(edge, ends), 0.02 + pixelRadius))
        }
        if cover <= 0 { return .one }
        let frost = 0.85 - 0.025 * FilmEdgeNoise.value(a / 0.3, t / 0.3, seed(45))
        let age = distress.tapeAge
        let tint = SIMD3(frost, frost * (1 - 0.1 * age), frost * (1 - 0.38 * age))
        return 1 - cover * (1 - tint)
    }
    struct TapePiece: Sendable { let side, inner, start, end, order: Double }
    static func tapePieces(_ d: FilmEdgeDistress, halfAlong ha: Double, halfAcross ht: Double, gateAcross: Double) -> [TapePiece] {
        var h = streamSeed(d.seed, 46)
        func next() -> Double { h = FilmEdgeNoise.hash(h); return FilmEdgeNoise.unit(h) }
        let first: Double = next() < 0.5 ? -1 : 1
        let reach = max(0.2, ht - gateAcross - 0.08)
        return (0..<2).map { i in
            let side = i == 0 ? first : -first
            let inner = ht - (0.35 + 0.65 * next()) * reach
            let start = -ha - 2 + next() * ha * 0.9, end = ha + 2 - next() * ha * 0.9
            return TapePiece(side: side, inner: inner, start: start, end: end, order: Double(i))
        }
    }

    /// Opaque particles on the developed film: specks and fibres, in film millimetres.
    func dustOcclusion(x: Int, y: Int) -> Double {
        let density = distress.dust
        guard density > 0 else { return 0 }
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        let (a, t) = strip(fx, fy)
        let cell = 1.6, pr = pixelRadius
        let ci = Int32(floor(a / cell)), cj = Int32(floor(t / cell))
        var clear = 1.0
        let s = seed(9)
        for dj in Int32(-1)...1 { for di in Int32(-1)...1 {
            let i = ci &+ di, j = cj &+ dj
            let h0 = FilmEdgeNoise.hash(i, j, s)
            let activation = min(max((density * 0.45 - FilmEdgeNoise.unit(h0)) / 0.04, 0), 1)
            if activation <= 0 { continue }
            let h1 = FilmEdgeNoise.hash(h0), h2 = FilmEdgeNoise.hash(h1), h3 = FilmEdgeNoise.hash(h2)
            let h4 = FilmEdgeNoise.hash(h3)
            let pa = (Double(i) + FilmEdgeNoise.unit(h1)) * cell - a
            let pt = (Double(j) + FilmEdgeNoise.unit(h2)) * cell - t
            let kind = FilmEdgeNoise.unit(h3), size = FilmEdgeNoise.unit(h4)
            var cover: Double
            if kind < 0.75 {
                let rho = 0.008 + 0.045 * size * size
                let rr = max(rho, pr * 0.9)
                cover = (rho / rr) * (rho / rr) * FilmEdgeNoise.penumbra(hypot(pa, pt) - rr, pr)
            } else {
                let angle = kind * 25.1327, length = 0.12 + 0.6 * size
                let ux = cos(angle), uy = sin(angle)
                let along = min(max(-(pa * ux + pt * uy), -length / 2), length / 2)
                let distance = hypot(-pa - along * ux, -pt - along * uy)
                let rho = 0.005 + 0.008 * FilmEdgeNoise.unit(FilmEdgeNoise.hash(h4))
                let rr = max(rho, pr * 0.9)
                cover = (rho / rr) * FilmEdgeNoise.penumbra(distance - rr, pr)
            }
            clear *= 1 - cover * activation * (0.85 + 0.15 * size)
        }}
        return 1 - clear
    }

    /// Seeded scratch candidates; Strength activates them in order so none jumps.
    /// `depth` > 0 is an emulsion scratch cutting that fraction of the dye stack from the top;
    /// `depth` < 0 is a scatter scratch (base side or a light scuff) of strength |depth|.
    struct Scratch: Sendable { let across, slope, wander, wavelength, phase, start, end, width, depth: Double }
    static func scratches(_ d: FilmEdgeDistress, halfAlong ha: Double, halfAcross ht: Double, gateAcross: Double) -> [Scratch] {
        (0..<scratchCount).map { k in
            var h = streamSeed(d.seed, UInt32(20 + k))
            func next() -> Double { h = FilmEdgeNoise.hash(h); return FilmEdgeNoise.unit(h) }
            // Transport scratches from rails, sprockets and gate debris: long, nearly straight.
            let side: Double = next() < 0.5 ? -1 : 1
            let inner = gateAcross + 0.12, outer = max(inner + 0.05, ht - 0.03)
            let across = d.scratchesInImage ? (next() * 2 - 1) * ht : side * (inner + (outer - inner) * next())
            let slope = (next() * 2 - 1) * 0.0015
            let wander = 0.002 + 0.018 * next(), wavelength = 40 + 120 * next(), phase = next() * 6.2832
            let span = ha * (0.9 + 1.3 * next()), center = (next() * 2 - 1) * ha
            let width = 0.005 + 0.014 * next()
            let emulsion = next() < 0.4
            let depth = emulsion ? 0.05 + 0.95 * pow(next(), 1.6) : -(0.25 + 0.45 * next())
            return Scratch(across: across, slope: slope, wander: wander, wavelength: wavelength, phase: phase,
                           start: center - span, end: center + span, width: width, depth: depth)
        }
    }
    /// Dye removed by emulsion scratches, top layer first. Colour film (still, cine and reversal)
    /// is coated blue-sensitive/yellow on top, then green/magenta, then red/cyan nearest the base;
    /// density channels are (cyan, magenta, yellow). The print or scan then decides the colour:
    /// a shallow cut prints yellow from a negative, looks blue on a slide or the negative itself.
    struct ScratchFields: Sendable { var removal = SIMD3<Double>.zero; var scatter = 0.0 }
    func scratchFields(x: Int, y: Int) -> ScratchFields {
        var result = ScratchFields()
        let amount = distress.scratches
        guard amount > 0 else { return result }
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        let (a, t) = strip(fx, fy)
        let pr = pixelRadius
        var outside = 1.0
        if !distress.scratchesInImage {
            let (hx, hy) = gateHalf
            outside = 1 - FilmEdgeNoise.penumbra(FilmEdgeNoise.box(fx, fy, hx, hy, Self.gateCorner), pr)
            if outside <= 0 { return result }
        }
        for (k, s) in scratchCandidates.enumerated() {
            let active = min(max(amount * Double(Self.scratchCount) - Double(k), 0), 1)
            if active <= 0 { continue }
            let ends = min(max((a - s.start) / 2, 0), 1) * min(max((s.end - a) / 2, 0), 1)
            if ends <= 0 { continue }
            let line = s.across + s.slope * a + s.wander * sin(a / s.wavelength * 6.2832 + s.phase)
            let rr = max(s.width, pr * 0.9)
            if abs(t - line) > rr + pr { continue }
            // Pressure varies along the run: the scratch breaks up and fades rather than drawing a ruler line.
            let pressure = FilmEdgeNoise.value(a / 2.5, Double(k) * 7.31, seed(30))
            let broken = min(max((pressure + 0.45) / 0.5, 0), 1)
            let cover = (s.width / rr) * FilmEdgeNoise.penumbra(abs(t - line) - rr, pr) * ends * active * broken * outside
            if s.depth > 0 {
                let d = s.depth * 3
                let r = SIMD3(min(max(d - 2, 0), 1), min(max(d - 1, 0), 1), min(max(d, 0), 1)) * cover
                result.removal = SIMD3(max(result.removal.x, r.x), max(result.removal.y, r.y), max(result.removal.z, r.z))
            } else {
                result.scatter = max(result.scatter, -s.depth * cover)
            }
        }
        return result
    }
    /// Scattering removes more short-wavelength light from the transmitted beam; per output channel.
    static let scatterWeights = SIMD3<Double>(0.55, 0.75, 1.0)
    var hasEmulsionScratches: Bool { distress.scratches > 0 && scratchCandidates.contains { $0.depth > 0 } }

    /// Combine intact film and clear light in transmission; never average densities with air.
    func transmit(_ film: SIMD3<Double>, clear: SIMD3<Double>, x: Int, y: Int, mode: Transmission) -> SIMD3<Double> {
        let support = supportCoverage(x: x, y: y, destination: mode.contains(.destination))
        let carrier = mode.contains(.carrier) ? carrierCoverage(x: x, y: y) : 1
        let tape = mode.contains(.carrier) ? tapeTransmission(x: x, y: y) : .one
        if mode.contains(.endpoint) {
            // Clear openings are the black reference, except where tape covers them.
            let taped = 1 - (tape.x + tape.y + tape.z) / 3 / 0.85
            return film * (1 - carrier * (1 - support) * (1 - min(max(taped, 0), 1)))
        }
        var occlusion = SIMD3<Double>.zero
        if mode.contains(.damage) {
            let dust = dustOcclusion(x: x, y: y), scatter = scratchFields(x: x, y: y).scatter
            let shoulder = perforationShoulder(x: x, y: y)
            occlusion = 1 - (1 - dust) * (1 - shoulder) * (1 - scatter * Self.scatterWeights)
        }
        var light = (film * support + clear * (1 - support)) * (1 - occlusion * support) * tape * carrier
        if mode.contains(.reflection) { light += clear * carrierReflection(x: x, y: y) * carrier }
        return light
    }
    /// Emulsion scratches thin the developed dye before printing or scanning.
    func scratchedDensity(_ density: SIMD3<Double>, x: Int, y: Int) -> SIMD3<Double> {
        density * (1 - scratchFields(x: x, y: y).removal)
    }

    /// Matches the Metal edge kernels. No full-frame mask bitmap is allocated.
    func uniforms(light: SIMD3<Double> = .zero, fogLight: SIMD3<Double> = .zero) -> [SIMD4<Float>] {
        let d = distress
        let ha = Double(portrait ? height : width) * millimetersPerPixel / 2
        let ht = Double(portrait ? width : height) * millimetersPerPixel / 2
        let (gx, gy) = gateHalf
        let leak = leakFrame
        var values: [SIMD4<Float>] = [
            SIMD4(Float(width), Float(height), Float(millimetersPerPixel), portrait ? 1 : 0),
            SIMD4(Float(gx), Float(gy), Float(Self.gateCorner), Float(d.gateSoftness)),
            SIMD4(format == .film35 ? 1 : 0, Float(Self.holeCenter), Float(Self.holeRadius), d.scratchesInImage ? 1 : 0),
            SIMD4(0, 0, Float(cos(tiltRadians)), Float(sin(tiltRadians))),
            SIMD4(Float(d.seed & 0xffff), Float(d.seed >> 16), Float(stockHalf), Float(d.gateWear)),
            SIMD4(Float(d.carrierRoughness), Float(d.carrierScale), Float(ha), Float(ht)),
            SIMD4(Float(d.edgeFog), Float(d.fogDepth), Float(d.leak), Float(d.leakSize)),
            SIMD4(Float(leak.point.0), Float(leak.point.1), Float(leak.normal.0), Float(leak.normal.1)),
            SIMD4(Float(leak.offset), Float(leak.weight), Float(d.dust), Float(d.scratches)),
            SIMD4(Float(light.x), Float(light.y), Float(light.z), 0),
            SIMD4(Float(perforation.rawValue), Float(perforation.pitch), Float(perforation.halfAlong), Float(perforation.halfAcross)),
            SIMD4(0, Float(Perforation.ks1870.pitch), Float(Perforation.ks1870.halfAlong), Float(Perforation.ks1870.halfAcross)),
            SIMD4(Float(d.perforationWear), Float(d.perforationLeak), d.leakKind == .front ? 1 : 0,
                  Float(FilmEdgeDistress.LeakShape.allCases.firstIndex(of: d.leakShape)!)),
            SIMD4(Float(fogLight.x), Float(fogLight.y), Float(fogLight.z), Float(d.carrierReflection)),
            SIMD4(Float(d.tape), Float(d.tapeAge), Float(leak.direction.0), Float(leak.direction.1)),
        ]
        for piece in tapePieces {
            values.append(SIMD4(Float(piece.side), Float(piece.inner), Float(piece.start), Float(piece.end)))
        }
        for s in scratchCandidates {
            values.append(SIMD4(Float(s.across), Float(s.wander), Float(s.wavelength), Float(s.phase)))
            values.append(SIMD4(Float(s.start), Float(s.end), Float(s.width), Float(s.depth)))
            values.append(SIMD4(Float(s.slope), 0, 0, 0))
        }
        return values
    }
    /// The layer exposure carried by unwanted light. Warm: through the base, mostly the red-sensitive
    /// layer (orange/red on a print). Cool: front light reaches the blue-sensitive top layer first
    /// (white/blue on a print). An empirical, uncalibrated blend around the stock's neutral response.
    static func light(neutral: SIMD3<Double>, warmth w: Double) -> SIMD3<Double> {
        if w >= 0 { return neutral * (1 - w) + SIMD3(neutral.x, neutral.x * 0.16, neutral.x * 0.04) * w }
        return neutral * (1 + w) + SIMD3(neutral.x * 0.45, neutral.y * 0.7, neutral.z) * -w
    }
    func leakLight(neutral: SIMD3<Double>) -> SIMD3<Double> { Self.light(neutral: neutral, warmth: distress.warmth) }
    /// Edge piping and perforation fog travel in the base.
    func fogLight(neutral: SIMD3<Double>) -> SIMD3<Double> { Self.light(neutral: neutral, warmth: 0.7) }
    var hasExposureNoise: Bool { distress.edgeFog > 0 || distress.leak > 0 || (distress.perforationLeak > 0 && format == .film35) }
}

extension EditRecipe {
    /// Normalize old adaptive v5 recipes as well as live crop edits. Never mutate Develop.
    nonisolated mutating func constrainFilmEdgeCrop(imageSize: CGSize) {
        guard let filmEdgeLayout else { return }
        let upright = geometry.quarterTurns % 2 == 0 ? imageSize
            : CGSize(width: imageSize.height, height: imageSize.width)
        crop = filmEdgeLayout.constrainedCrop(crop, imageSize: upright)
    }
}
