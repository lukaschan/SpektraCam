import CoreGraphics
import Foundation

/// A saved capture-support presentation. Nil in EditRecipe means Clean print.
/// `gate` describes the camera and holder (fixed per setup); `distress` how the film was handled.
nonisolated struct FilmEdgeLayout: Codable, Equatable, Sendable {
    enum Format: String, Codable, CaseIterable, Sendable { case film35, roll120 }
    var format = Format.film35
    /// Motion-picture stock respooled for a still camera keeps BH-1866 holes (e.g. Ektachrome 100D
    /// 5294, Vision3). Off means the holes follow the chosen stock.
    var cinePerforations = false
    /// 120 frame sizes (nominal name, actual gate in mm). The 56 mm side always spans the film.
    enum RollFrame: String, Codable, CaseIterable, Sendable {
        case six45, six6, six7, six9
        var title: String {
            switch self { case .six45: "6 × 4.5"; case .six6: "6 × 6"; case .six7: "6 × 7"; case .six9: "6 × 9" }
        }
        /// Gate length along the film.
        var along: Double {
            switch self { case .six45: 41.5; case .six6: 56; case .six7: 69.5; case .six9: 84 }
        }
    }
    var rollFrame = RollFrame.six6
    /// The camera body's gate. Hasselblad V magazines cut two small V notches into the left edge,
    /// which print as ticks of picture in the rebate; a toy camera's moulded mask is soft and round.
    enum RollGate: String, Codable, CaseIterable, Sendable {
        case plain, hasselblad, toy
        var title: String {
            switch self {
            case .plain: String(localized: "darkroom.rollgate.plain", defaultValue: "Plain")
            case .hasselblad: "V"
            case .toy: "Holga"
            }
        }
    }
    var rollGate = RollGate.hasselblad
    var gate = FilmEdgeGate()
    var distress = FilmEdgeDistress()
    /// Enlarger print only: how large the projected frame is relative to the easel opening, set
    /// by raising or lowering the enlarger head. 100 % puts the blades on the frame edge; below,
    /// the opening shows a black band of rebate (at 90 % the holes start to show); above, the
    /// blades crop into the picture. The blades keep the frame's proportions.
    var printZoom = 0.97
    static let printZoomRange = 0.9...1.1
    /// Enlarger print: paper rendered around the easel opening, in fractions of the frame's long
    /// side; room for a hand-set blade's miss and its penumbra. The rest of the sheet is composited.
    static let easelMargin = 0.025
    /// The nominal easel opening inside an enlarger-print canvas of `size`, in unit coordinates.
    func easelFrame(canvas size: CGSize) -> CGRect {
        let halfLong = max(gateAlong, gateAcross) / 2 / printZoom, halfShort = min(gateAlong, gateAcross) / 2 / printZoom
        let margin = Self.easelMargin * max(gateAlong, gateAcross)
        let long = halfLong / (halfLong + margin), short = halfShort / (halfShort + margin)
        let (fx, fy) = size.width >= size.height ? (long, short) : (short, long)
        return CGRect(x: (1 - fx) / 2, y: (1 - fy) / 2, width: fx, height: fy)
    }
    /// Rebate shown beyond the frame on film (positive) or picture cropped (negative), in mm,
    /// at the frame's ends and along its sides.
    var easelBorder: (ends: Double, sides: Double) {
        (gateAlong / 2 * (1 / printZoom - 1), gateAcross / 2 * (1 / printZoom - 1))
    }
    /// A new film edge: Natural gate, Lab scan handling.
    static func newDefault() -> Self {
        var layout = Self()
        layout.distress.apply(.lab)
        return layout
    }
    /// Gate along and across the film, in mm.
    var gateAlong: Double { format == .film35 ? 36 : rollFrame.along }
    var gateAcross: Double { format == .film35 ? 24 : 56 }
    /// Long × short.
    var gateSize: CGSize { CGSize(width: max(gateAlong, gateAcross), height: min(gateAlong, gateAcross)) }
    var isSquare: Bool { gateAlong == gateAcross }
    var cropAspect: CropAspect {
        guard format == .roll120 else { return .threeTwo }
        switch rollFrame { case .six45: return .roll645; case .six6: return .rollSquare; case .six7: return .roll67; case .six9: return .threeTwo }
    }
    func gateTitle(portrait: Bool) -> String {
        func mm(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        let long = mm(gateSize.width), short = mm(gateSize.height)
        return isSquare ? "\(long) × \(short) mm" : portrait ? "\(short) × \(long) mm" : "\(long) × \(short) mm"
    }
    func constrainedCrop(_ crop: CropSelection, imageSize: CGSize) -> CropSelection {
        guard imageSize.width > 0, imageSize.height > 0 else { return crop }
        var result = crop
        let current = crop.normalizedRect
        let portrait = !isSquare && current.width * imageSize.width < current.height * imageSize.height
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
    enum CodingKeys: String, CodingKey { case format, cinePerforations, rollFrame, rollGate, gate, distress, printZoom }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decodeIfPresent(Format.self, forKey: .format) ?? .film35
        cinePerforations = try values.decodeIfPresent(Bool.self, forKey: .cinePerforations) ?? false
        rollFrame = try values.decodeIfPresent(RollFrame.self, forKey: .rollFrame) ?? .six6
        rollGate = try values.decodeIfPresent(RollGate.self, forKey: .rollGate) ?? .hasselblad
        gate = (try? values.decodeIfPresent(FilmEdgeGate.self, forKey: .gate)) ?? FilmEdgeGate()
        distress = try values.decodeIfPresent(FilmEdgeDistress.self, forKey: .distress) ?? FilmEdgeDistress()
        let zoom = try values.decodeIfPresent(Double.self, forKey: .printZoom) ?? 0.97
        printZoom = zoom.isFinite ? min(max(zoom, Self.printZoomRange.lowerBound), Self.printZoomRange.upperBound) : 0.97
    }
}

/// The camera aperture and the scanner holder: properties of the equipment, not of handling.
/// Softness is the gate penumbra (≈ gap / 2N); wear roughens the aperture edge; the holder edge is
/// out of focus (crisp core plus a faint tail) with abraded specks; tilt and bulge are the
/// setup's inherent misalignment and film flatness. Engineering values, not camera measurements.
nonisolated struct FilmEdgeGate: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case precise, natural, loose, rough
        var title: String {
            switch self {
            case .precise: String(localized: "darkroom.gate.precise", defaultValue: "Precise")
            case .natural: String(localized: "darkroom.gate.natural", defaultValue: "Natural")
            case .loose: String(localized: "darkroom.gate.loose", defaultValue: "Loose")
            case .rough: String(localized: "darkroom.gate.rough", defaultValue: "Rough")
            }
        }
    }
    var softness = 0.03
    var wear = 0.02
    var holderBlur = 0.1
    var holderDetail = 0.35
    /// Degrees; the direction comes from the edit's seed.
    var tilt = 0.2
    /// −1 film dip … +1 strong bulge (edges bow up to ~0.2 mm).
    var bulge = 0.25

    init() {}
    init(_ kind: Kind) {
        switch kind {
        case .precise: softness = 0.03; wear = 0.02; holderBlur = 0.06; holderDetail = 0.2; tilt = 0; bulge = 0
        case .natural: break
        case .loose: softness = 0.05; wear = 0.04; holderBlur = 0.16; holderDetail = 0.5; tilt = 0.5; bulge = 0.6
        case .rough: softness = 0.05; wear = 0.04; holderBlur = 0.22; holderDetail = 0.65; tilt = 0.8; bulge = 1
        }
    }
    var kind: Kind? { Kind.allCases.first { Self($0) == self } }
    enum CodingKeys: String, CodingKey { case softness, wear, holderBlur, holderDetail, tilt, bulge }
    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self()
        softness = try v.decodeIfPresent(Double.self, forKey: .softness) ?? base.softness
        wear = try v.decodeIfPresent(Double.self, forKey: .wear) ?? base.wear
        holderBlur = try v.decodeIfPresent(Double.self, forKey: .holderBlur) ?? base.holderBlur
        holderDetail = try v.decodeIfPresent(Double.self, forKey: .holderDetail) ?? base.holderDetail
        tilt = try v.decodeIfPresent(Double.self, forKey: .tilt) ?? base.tilt
        bulge = try v.decodeIfPresent(Double.self, forKey: .bulge) ?? base.bulge
    }
}

/// Procedural, seeded imperfections from handling, in physical film millimetres. Every field is
/// placed at the stage where its mechanism acts (see Research/Darkroom-v0.3/DISTRESS-AND-LEAKS.md):
/// leaks and fog are exposure before development; scratches thin the developed dye or scatter
/// light; dust and the carrier act where the film is printed or scanned. `amount` scales only
/// intensities. These ranges are engineering choices, not calibrated measurements.
///
/// The optics fields below (`gateSoftness`, `gateWear`, `carrierBlur`, `carrierDetail`,
/// `carrierTail`, `fogDepth`, `perforationLeak`) are not saved: `FilmEdgeGeometry` resolves them
/// from the gate and from edge fog, so one parameter set feeds the CPU reference and Metal.
nonisolated struct FilmEdgeDistress: Codable, Equatable, Sendable {
    static let algorithmRevision = 4
    /// Through the lens (front) light is gated with the scene and reaches the top, blue-sensitive
    /// layer first; a back/door-seal leak bypasses the gate and enters through the base.
    enum LeakKind: String, Codable, CaseIterable, Sendable { case back, front }
    /// Burn: the fogged start of a roll, exposed past saturation, with a narrow wavy boundary.
    enum LeakShape: String, Codable, CaseIterable, Sendable { case glow, streak, flare, burn }
    var revision = Self.algorithmRevision
    var seed: UInt32 = 1
    var amount = 1.0
    /// Handling adds to the gate's own tilt and bulge: film loaded crooked, curled in the holder.
    var tilt = 0.0
    var bulge = 0.0
    /// Natural, always-present hole differences: punch tolerance between holes and the rim where
    /// light piped in through the cut hole wall — a bright streak on the picture side.
    var holeVariation = 0.5
    var carrierRoughness = 0.0
    /// Unmasked enlarger light reflected by a bare-metal carrier edge onto the paper (prints only).
    var carrierReflection = 0.0
    /// Printed on an enlarger (colour or black-and-white, the same optics) rather than scanned:
    /// the easel's straight blades mask the paper, and `FilmEdgeLayout.printZoom` decides how
    /// much rebate they show. Set from the edge type (a negative print), not by hand; see
    /// `EditRecipe.renderedFilmEdgeLayout`.
    var enlargerPrint = false
    var edgeFog = 0.0
    var leak = 0.0
    var leakKind = LeakKind.back
    var leakShape = LeakShape.glow
    var leakSize = 8.0
    var leakPosition = 0.3
    /// −1 cool (front, blue layer first) … 0 neutral … +1 warm (base, red layer first).
    var warmth = 0.6
    var dust = 0.0
    var scratches = 0.3
    /// Rails and sprockets touch only the rebate, so scratches stay there by default.
    /// Releasing the clamp lets gate debris drag scratches across the picture as well.
    var scratchesInImage = false

    // Resolved by FilmEdgeGeometry; not saved and not shown as distress controls.
    var gateSoftness = 0.03
    var gateWear = 0.02
    var carrierBlur = 0.1
    var carrierDetail = 0.35
    var carrierTail = 0.05
    var carrierTailWidth = 0.12
    var carrierScale = 1.2
    /// Inside corner of the opening: a milled holder is tight, a hand-filed carrier rounder.
    var carrierCorner = 0.2
    /// Slow wander of the outline around the frame (mm): no hand-filed side is straight or
    /// parallel, so the black border changes width along its length.
    var carrierWave = 0.02
    var fogDepth = 1.5
    var perforationLeak = 0.0

    static let ranges: [WritableKeyPath<Self, Double>: ClosedRange<Double>] = [
        \.amount: 0...2, \.tilt: -3...3, \.bulge: -1...1, \.holeVariation: 0...1,
        \.carrierRoughness: 0...0.5, \.carrierReflection: 0...1, \.edgeFog: 0...1,
        \.leak: 0...1, \.leakSize: 2...30, \.leakPosition: 0...1, \.warmth: -1...1,
        \.dust: 0...1, \.scratches: 0...1,
    ]
    static func defaultWarmth(_ kind: LeakKind) -> Double { kind == .front ? -0.4 : 0.6 }

    enum Preset: String, CaseIterable, Sendable {
        case clean, lab, worn, leaky
        var title: String {
            switch self {
            case .clean: String(localized: "darkroom.distress.clean", defaultValue: "Clean")
            case .lab: String(localized: "darkroom.distress.lab", defaultValue: "Lab scan")
            case .worn: String(localized: "darkroom.distress.worn", defaultValue: "Old camera")
            case .leaky: String(localized: "darkroom.distress.leaky", defaultValue: "Light leak")
            }
        }
        /// Every preset keeps natural hole variation and light rail scratches (30 %); only Old
        /// camera adds dust, full scratches, a crooked load and curl.
        var values: FilmEdgeDistress {
            var d = FilmEdgeDistress()
            switch self {
            case .clean: break
            case .lab:
                d.scratches = 0.5; d.edgeFog = 0.06
            case .worn:
                d.tilt = 1; d.bulge = 0.3; d.carrierRoughness = 0.08; d.holeVariation = 0.8
                d.edgeFog = 0.3; d.leak = 0.3; d.leakSize = 10; d.warmth = 0.7
                d.dust = 0.4; d.scratches = 1
            case .leaky:
                d.edgeFog = 0.35; d.leak = 0.5; d.leakShape = .flare; d.leakSize = 14; d.warmth = 0.8
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
    /// Intensities after the global Amount. Hole variation, sizes and colour are unchanged.
    var effective: Self {
        var e = self
        let a = max(0, amount)
        e.tilt *= a; e.bulge *= a; e.carrierRoughness *= a
        e.carrierReflection = min(1, carrierReflection * a)
        e.edgeFog = min(1, edgeFog * a); e.leak = min(1, leak * a)
        e.dust = min(1, dust * a); e.scratches = min(1, scratches * a)
        return e
    }

    init() {}
    enum CodingKeys: String, CodingKey {
        case revision, seed, amount, tilt, bulge, holeVariation, carrierRoughness, carrierReflection, enlargerPrint,
            edgeFog, leak, leakKind, leakShape, leakSize, leakPosition, warmth, dust, scratches, scratchesInImage
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(revision, forKey: .revision); try c.encode(seed, forKey: .seed); try c.encode(amount, forKey: .amount)
        try c.encode(tilt, forKey: .tilt); try c.encode(bulge, forKey: .bulge)
        try c.encode(holeVariation, forKey: .holeVariation)
        try c.encode(carrierRoughness, forKey: .carrierRoughness); try c.encode(carrierReflection, forKey: .carrierReflection)
        try c.encode(enlargerPrint, forKey: .enlargerPrint); try c.encode(edgeFog, forKey: .edgeFog)
        try c.encode(leak, forKey: .leak); try c.encode(leakKind, forKey: .leakKind); try c.encode(leakShape, forKey: .leakShape)
        try c.encode(leakSize, forKey: .leakSize); try c.encode(leakPosition, forKey: .leakPosition)
        try c.encode(warmth, forKey: .warmth); try c.encode(dust, forKey: .dust); try c.encode(scratches, forKey: .scratches)
        try c.encode(scratchesInImage, forKey: .scratchesInImage)
    }
    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self()
        func n(_ key: CodingKeys, _ path: KeyPath<Self, Double>) throws -> Double {
            try v.decodeIfPresent(Double.self, forKey: key) ?? base[keyPath: path]
        }
        revision = try v.decodeIfPresent(Int.self, forKey: .revision) ?? Self.algorithmRevision
        seed = try v.decodeIfPresent(UInt32.self, forKey: .seed) ?? 1
        amount = try n(.amount, \.amount)
        tilt = try n(.tilt, \.tilt)
        bulge = try n(.bulge, \.bulge)
        holeVariation = try n(.holeVariation, \.holeVariation)
        carrierRoughness = try n(.carrierRoughness, \.carrierRoughness)
        carrierReflection = try n(.carrierReflection, \.carrierReflection)
        enlargerPrint = try v.decodeIfPresent(Bool.self, forKey: .enlargerPrint) ?? false
        edgeFog = try n(.edgeFog, \.edgeFog)
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
    /// Seeded unevenness of a cut edge in [-1, 1], the same profile for the camera gate and the
    /// easel blades: a broad wander (0.9 mm) and a fine tooth (0.16 mm), in film millimetres.
    static func wear(_ x: Double, _ y: Double, _ broad: UInt32, _ fine: UInt32) -> Double {
        0.65 * value(x / 0.9, y / 0.9, broad) + 0.35 * value(x / 0.16, y / 0.16, fine)
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
    private(set) var width: Int, height: Int
    private(set) var gate: CGRect
    let format: FilmEdgeLayout.Format
    let portrait: Bool
    private(set) var millimetersPerPixel: Double
    let distress: FilmEdgeDistress
    /// Seeded, resolution-independent features, computed once per geometry.
    let leakFrame: LeakFrame
    let scratchCandidates: [Scratch]
    /// Carrier opening half sizes in transport/across axes (mm); the canvas extends past them so
    /// the out-of-focus holder edge is visible.
    let carrierHalf: (along: Double, across: Double)
    /// Enlarger print on a hand-set easel: the opening's centre relative to the frame, canvas mm.
    let easelOffset: (x: Double, y: Double)
    /// Creative routes: the material graph's scene stops at the inner edge of the penumbra, so a
    /// separately developed centre can fade straight into rebate without a rim of the material image.
    var erodesGate = false
    static let stockWidth = 34.975
    /// Veiling glare of a scan: fraction of light spread, and the spread's scale on the film.
    static let scanFlare = 0.035, scanFlareMicrometers = 220.0
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
    /// Gate corner radius, from prints: a 35 mm camera gate is nearly square (about 0.1 mm,
    /// measured on Ilford Multigrade enlargements);
    /// a Hasselblad magazine's is nearly square, a moulded toy-camera mask very round.
    let gateCorner: Double
    /// Hasselblad V notches: centres along the left edge (mm from the frame centre), depth and
    /// half width of a blunt triangle, measured from two full-resolution frames (about 51 px/mm).
    /// Estimates, not factory drawings.
    let notched: Bool
    static let notchCentres = (-2.7, 2.4), notchDepth = 0.34, notchHalfWidth = 0.42, notchTip = 0.26
    static let rollStockWidth = 61.0
    static let scratchCount = 16

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

    /// `easel` supplies a hand-set enlarger print's placement; nil prints square and centred.
    init?(imageSize: CGSize, layout: FilmEdgeLayout, longEdge: Int, perforation: Perforation = .ks1870,
          easel: PrintLayout? = nil) {
        guard imageSize.width > 0, imageSize.height > 0,
              imageSize.width.isFinite, imageSize.height.isFinite,
              longEdge > 0, longEdge <= 65_536, layout.matchesGate(imageSize) else { return nil }
        format = layout.format
        let roll = layout.format == .roll120
        gateCorner = !roll ? 0.1 : layout.rollGate == .toy ? 1.6 : 0.12
        notched = roll && layout.rollGate == .hasselblad
        self.perforation = perforation
        var resolved = Self.resolve(layout)
        // Set by eye, the projection lands a fraction of a degree off square and a little off
        // centre in the easel opening: the black rebate band tapers and differs side to side.
        let handSet = resolved.enlargerPrint && easel?.handSet == true
        let easelSeed = easel?.easelSeed ?? 1
        if handSet { resolved.tilt = min(max(resolved.tilt + 0.3 * Easel.jitter(easelSeed, 3), -3.3), 3.3) }
        // The blades' worn edge: the gate's wear profile at the easel's amplitude.
        if resolved.enlargerPrint { resolved.carrierRoughness = (easel?.blade ?? .natural).wear }
        distress = resolved
        easelOffset = handSet ? (0.18 * Easel.jitter(easelSeed, 4), 0.18 * Easel.jitter(easelSeed, 5)) : (0, 0)
        // `portrait` means the film runs vertically on the canvas. 6 × 4.5 frames lie across the
        // film, so a landscape 645 picture sits on a vertical strip.
        portrait = (imageSize.height > imageSize.width) == (layout.gateAlong >= layout.gateAcross)
        let short = layout.gateAcross
        let long = layout.gateAlong
        // Scan: the holder opening plus room for its out-of-focus edge; the canvas never changes.
        // Enlarger print: the easel opening (the frame scaled by the print zoom) plus a margin of
        // the same sheet, wide enough for a hand-set offset and the blade's penumbra.
        let extent: CGSize
        if distress.enlargerPrint {
            carrierHalf = (long / 2 / layout.printZoom, short / 2 / layout.printZoom)
            let margin = FilmEdgeLayout.easelMargin * max(long, short)
            extent = CGSize(width: 2 * (carrierHalf.along + margin), height: 2 * (carrierHalf.across + margin))
        } else {
            let alongReveal = 0.8, acrossReveal = format == .film35 ? 1.1 : 0.8, holder = 0.4
            carrierHalf = (long / 2 + alongReveal, short / 2 + acrossReveal)
            extent = CGSize(width: long + 2 * (alongReveal + holder), height: short + 2 * (acrossReveal + holder))
        }
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
        scratchCandidates = Self.scratches(distress, halfAlong: ha, halfAcross: carrierHalf.across, gateAcross: short / 2)
    }

    var pixelPitchMicrometers: Double { millimetersPerPixel * 1000 }
    /// The same strip, carrier and seeded features on a canvas `factor` times coarser: the
    /// low-resolution proxy of a region render. Everything else is defined in millimetres.
    func coarser(by factor: Int) -> FilmEdgeGeometry {
        var copy = self
        let f = Double(factor)
        copy.width = (width + factor - 1) / factor
        copy.height = (height + factor - 1) / factor
        copy.millimetersPerPixel = millimetersPerPixel * f
        copy.gate = CGRect(x: gate.minX / f, y: gate.minY / f, width: gate.width / f, height: gate.height / f)
        return copy
    }
    /// One resolved parameter set: handling distress (after Amount) plus the gate's optics. Gate
    /// tilt and bulge add to handling; the gate tilt's direction comes from the seed.
    static func resolve(_ layout: FilmEdgeLayout) -> FilmEdgeDistress {
        var d = layout.distress.effective
        let g = layout.gate
        let toy = layout.format == .roll120 && layout.rollGate == .toy
        d.gateSoftness = toy ? max(g.softness, 0.22) : g.softness
        d.gateWear = toy ? max(g.wear, 0.1) : g.wear
        if d.enlargerPrint {
            // Easel blades: straight, square-cornered and opaque, with no halo or reflection. Their
            // penumbra (`Easel`) for a nominal 6-inch print, in film mm; the radius is half the ramp.
            let m = 152.4 / max(layout.gateAlong, layout.gateAcross)
            d.carrierBlur = Easel.penumbra(magnification: m) / m / 2
            d.carrierDetail = 0; d.carrierTail = 0; d.carrierTailWidth = 0.1
            d.carrierCorner = 0.01; d.carrierWave = 0
            d.carrierRoughness = 0; d.carrierReflection = 0
        } else {
            // A scan holder is out of focus and scatters a short tail.
            d.carrierBlur = g.holderBlur
            d.carrierDetail = g.holderDetail
            d.carrierTail = 0.08
            d.carrierTailWidth = 0.12
            d.carrierCorner = 0.2
            d.carrierWave = 0.02
        }
        let sign: Double = streamSeed(d.seed, 60) & 1 == 0 ? 1 : -1
        d.tilt = min(max(g.tilt * sign + d.tilt, -3), 3)
        d.bulge = min(max(g.bulge + d.bulge, -1.5), 1.5)
        // Edge fog also pipes in through the perforations of the wrap above, and reaches deeper.
        d.perforationLeak = min(1, 0.8 * d.edgeFog)
        d.fogDepth = 1.5 + 3 * d.edgeFog
        return d
    }
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

    /// Signed distance to the camera aperture in film x/y (> 0 outside). Film that is not flat
    /// (bulge > 0) or dips (< 0) bows the outline: up to ~0.22 mm on the long edges and
    /// ~0.15 mm on the short ones at full bulge.
    func gateDistance(_ fx: Double, _ fy: Double) -> Double {
        var (hx, hy) = gateHalf
        let ux = min(max(fx / hx, -1), 1), uy = min(max(fy / hy, -1), 1)
        let b = distress.bulge
        hx += 0.15 * b * (1 - uy * uy)
        hy += 0.22 * b * (1 - ux * ux)
        var d = FilmEdgeNoise.box(fx, fy, hx, hy, gateCorner)
        if notched {
            // Each notch is a small triangle of open gate pointing out of the left edge.
            let u = -(fx + hx), slope = (Self.notchDepth * Self.notchDepth + Self.notchHalfWidth * Self.notchHalfWidth).squareRoot()
            for centre in [Self.notchCentres.0, Self.notchCentres.1] {
                let v = abs(fy - centre)
                let side = (v * Self.notchDepth + u * Self.notchHalfWidth - Self.notchHalfWidth * Self.notchDepth) / slope
                d = min(d, max(side, max(-u - 0.3, u - Self.notchTip)))
            }
        }
        return d
    }
    /// Camera-gate exposure coverage: penumbra, pixel area and seeded wear of the aperture edge.
    func gateCoverage(x: Int, y: Int) -> Double {
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        let base = gateDistance(fx, fy)
        let r = (distress.gateSoftness * distress.gateSoftness + pixelRadius * pixelRadius).squareRoot()
        let wear = distress.gateWear
        let shift = erodesGate ? r + wear : 0
        if base + shift < -(r + wear) { return 1 }
        if base + shift > r + wear { return 0 }
        var d = base
        if wear > 0 {
            let (a, t) = strip(fx, fy)
            d += wear * FilmEdgeNoise.wear(a, t, seed(1), seed(2))
        }
        return erodesGate ? FilmEdgeNoise.penumbra(d + shift, pixelRadius) : FilmEdgeNoise.penumbra(d, r)
    }

    /// Unwanted exposure, relative to a mid-grey scene exposure. `front` light comes through the
    /// lens and is gated with the scene; `back` (door/seal) light bypasses the gate; `fog` is
    /// base-path light: edge piping from the long film edges and perforation-shaped fog where
    /// light shone through the holes of the outer wrap onto the next one.
    struct Exposure: Sendable { var front = 0.0, back = 0.0, fog = 0.0, core = 0.0 }
    func exposureFields(x: Int, y: Int) -> Exposure {
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        return exposureFields(filmX: fx, filmY: fy)
    }
    /// The same fields at a point in film millimetres (origin at the frame centre).
    func exposureFields(filmX fx: Double, filmY fy: Double) -> Exposure {
        let (a, t) = strip(fx, fy)
        var e = Exposure()
        if distress.edgeFog > 0 {
            let distance = max(0, stockHalf - abs(t))
            let n = FilmEdgeNoise.value(a / 6, t > 0 ? 3.5 : -3.5, seed(3))
            e.fog += 6 * distress.edgeFog * distress.edgeFog * exp(-distance / distress.fogDepth) * (0.6 + 0.4 * n)
        }
        if distress.perforationLeak > 0 && format == .film35 { e.fog += perforationFog(a, t) }
        if distress.holeVariation > 0 && format == .film35 {
            let rim = holeRim(a, t)
            e.fog += rim.warm
            e.core += rim.core
        }
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
        case .burn:
            // Saturating exposure up to a wavy front `size` mm in; the fall-off is a fraction of that.
            let front = size * (1 + 0.14 * FilmEdgeNoise.value(lateral / (0.5 * size), 0.5, seed(4))
                + 0.04 * FilmEdgeNoise.value(lateral / (0.08 * size), 1.5, seed(4)))
            return 60 / (1 + exp(min((depth - front) / (0.045 * size + 0.12), 40)))
        case .flare:
            let broad = exp(-lateral * lateral / (2 * pow(3 * size, 2)))
            let band = 0.8 + 0.2 * FilmEdgeNoise.value(lateral / (1.5 * size), 0.5, seed(4))
            return exp(-depth / (2.2 * size)) * broad * band
        }
    }
    /// Light piped in through the cut hole wall fogs a rim around each hole, from the base side:
    /// red-sensitive layer first (orange on a print or inverted scan), and right at the wall it
    /// reaches the green layer too (a bright yellow core). The flat edge facing the picture
    /// catches the most light, as a streak along the edge with sparkle where the emulsion broke.
    private func holeRim(_ a: Double, _ t: Double) -> (warm: Double, core: Double) {
        let hole = jittered(perforation.hole(along: a, across: t), perforation)
        guard hole.distance > -0.004, hole.distance < 0.2 else { return (0, 0) }
        let v = distress.holeVariation
        let h = FilmEdgeNoise.hash(hole.index, hole.side, seed(47))
        let strength = 0.35 + 0.65 * FilmEdgeNoise.unit(h)
        let d = max(hole.distance, 0)
        let toward0 = min(max((-hole.t / perforation.halfAcross - 0.55) / 0.35, 0), 1)
        let toward = toward0 * toward0 * (3 - 2 * toward0)
        let side = 0.45 + 1.55 * toward
        let streak = min(max(0.25 + 0.75 * FilmEdgeNoise.value(hole.local / 0.12, hole.t / 0.025 + Double(hole.index) * 5.3, seed(48)), 0), 1)
        let halo = 3 * v * strength * side * streak * exp(-d / 0.03)
        let core = 10 * v * strength * toward * (0.55 + 0.45 * streak) * exp(-d / 0.014)
        let spark0 = min(max((FilmEdgeNoise.value(hole.local / 0.012, hole.t / 0.012, seed(52)) - 0.35) / 0.4, 0), 1)
        let sparkle = 1.5 * v * toward * spark0 * spark0 * (3 - 2 * spark0) * exp(-d / 0.05) * min(d / 0.01, 1)
        return (halo + sparkle, core)
    }
    /// The perforation-shaped part of edge fog alone, for checks.
    func perforationFogExposure(x: Int, y: Int) -> Double {
        guard distress.perforationLeak > 0, format == .film35 else { return 0 }
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        let (a, t) = strip(fx, fy)
        return perforationFog(a, t)
    }
    /// The hole-wall rim alone (base-path halo, yellow core), for checks.
    func holeRimExposure(x: Int, y: Int) -> (warm: Double, core: Double) {
        guard distress.holeVariation > 0, format == .film35 else { return (0, 0) }
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        let (a, t) = strip(fx, fy)
        return holeRim(a, t)
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
        let vary = !destination && distress.holeVariation > 0
        var covered = 0.0
        for sy in 0..<4 { for sx in 0..<4 {
            let (fx, fy) = film(Double(x) + (Double(sx) + 0.5) / 4, Double(y) + (Double(sy) + 0.5) / 4)
            let (along, across) = strip(fx, fy)
            // Centered frame; phase is fixed, with no random shuffling.
            var hole = kind.hole(along: along, across: across)
            if vary && abs(hole.distance) < 0.1 { hole = jittered(hole, kind) }
            if hole.distance >= 0 { covered += 1 }
        }}
        return covered / 16
    }
    /// Punch tolerance: each hole sits and sizes a few microns differently, with a faint edge texture.
    func jittered(_ hole: Perforation.Hole, _ kind: Perforation) -> Perforation.Hole {
        let v = distress.holeVariation, s = seed(40)
        var h = FilmEdgeNoise.hash(hole.index, hole.side, s)
        func next() -> Double { h = FilmEdgeNoise.hash(h); return FilmEdgeNoise.unit(h) * 2 - 1 }
        let da = 0.012 * v * next(), dt = 0.01 * v * next(), grow = 0.008 * v * next()
        let local = hole.local - da, t = hole.t - dt
        let rough = 0.003 * v * FilmEdgeNoise.value(local / 0.045 + Double(hole.index) * 3.7, t / 0.045 + Double(hole.side) * 11.1, s)
        return Perforation.Hole(index: hole.index, side: hole.side, local: local, t: t,
                                distance: kind.distance(local: local, t: t) - grow + rough)
    }

    /// Signed distance to the carrier/holder opening (> 0 where it blocks light), fixed to the
    /// canvas: the film can tilt inside it.
    func carrierDistance(x: Int, y: Int) -> Double {
        let (px, py) = canvas(Double(x) + 0.5, Double(y) + 0.5)
        let cx = px - easelOffset.x, cy = py - easelOffset.y
        let (hx, hy) = portrait ? (carrierHalf.across, carrierHalf.along) : (carrierHalf.along, carrierHalf.across)
        let (a, t) = strip(cx, cy)
        let base = FilmEdgeNoise.box(cx, cy, hx, hy, distress.carrierCorner)
            + distress.carrierWave * FilmEdgeNoise.value(a / 11, t / 11, seed(52))
        let amplitude = distress.carrierRoughness
        guard amplitude > 0, base > -(amplitude * 1.6 + pixelRadius + distress.carrierBlur) else { return base }
        // Easel blades: the gate's wear profile, centred on the blade's line.
        if distress.enlargerPrint { return base + amplitude * FilmEdgeNoise.wear(a, t, seed(54), seed(55)) }
        let scale = distress.carrierScale
        // Mostly smooth filing with a little file-tooth texture and a few sparse nicks.
        let broad = 0.5 + 0.5 * (0.85 * FilmEdgeNoise.value(a / scale, t / scale, seed(6))
            + 0.15 * FilmEdgeNoise.value(a / (0.2 * scale), t / (0.2 * scale), seed(7)))
        let n = FilmEdgeNoise.value(a / (0.35 * scale), t / (0.35 * scale), seed(8))
        let notch = min(max((n - 0.6) / 0.3, 0), 1)
        return base + amplitude * (broad + 0.5 * notch * notch * (3 - 2 * notch))
    }
    /// Light passed by the holder: a crisp core (its defocus) plus a faint wide tail of scattered
    /// light, and specks of light through an abraded edge. On an inverted negative the faint tail
    /// prints as a visible band; on a slide it disappears into black, as in real scans.
    func carrierCoverage(x: Int, y: Int) -> Double {
        let d = carrierDistance(x: x, y: y)
        let r = max(distress.carrierBlur, pixelRadius)
        if d < -r { return 1 }
        let open = FilmEdgeNoise.penumbra(d, r)
        // An enlarger carrier is opaque; its scattered light carries no image (see `carrierHalo`).
        if distress.enlargerPrint { return open }
        var pass = open + (1 - open) * distress.carrierTail * exp(-max(d, 0) / distress.carrierTailWidth)
        let detail = distress.carrierDetail
        guard detail > 0 else { return pass }
        let (cx, cy) = canvas(Double(x) + 0.5, Double(y) + 0.5)
        if d > -2.6 { pass *= 1 - holderFibres(cx, cy) }
        guard d < r + 0.45 else { return pass }
        let (a, t) = strip(cx, cy)
        // Organic abrasion: two octaves, a soft threshold, patchy along the edge, densest at it.
        let n = 0.6 * FilmEdgeNoise.value(a / 0.05, t / 0.05, seed(49)) + 0.4 * FilmEdgeNoise.value(a / 0.15, t / 0.15, seed(51))
        let u = min(max((n - 0.15) / 0.55, 0), 1)
        let patch = 0.5 + 0.5 * FilmEdgeNoise.value(a / 0.6, t / 0.6, seed(50))
        let speck = u * u * (3 - 2 * u) * patch * patch
        pass += (1 - pass) * detail * 0.5 * speck * exp(-max(d - r * 0.5, 0) / 0.12)
        return pass
    }
    /// Lint caught on the holder edge, in silhouette: a few hairs reach into the opening, rooted
    /// under the holder and as far out of focus as its edge. Canvas millimetres.
    static let fibreCount = 6
    func holderFibres(_ cx: Double, _ cy: Double) -> Double {
        let (hx, hy) = portrait ? (carrierHalf.across, carrierHalf.along) : (carrierHalf.along, carrierHalf.across)
        let detail = distress.carrierDetail, blur = max(pixelRadius, 0.5 * distress.carrierBlur)
        var clear = 1.0
        for k in 0..<Self.fibreCount {
            let h0 = FilmEdgeNoise.hash(Int32(k), 0, seed(53))
            guard FilmEdgeNoise.unit(h0) < 0.15 + 0.85 * detail else { continue }
            let h1 = FilmEdgeNoise.hash(h0), h2 = FilmEdgeNoise.hash(h1), h3 = FilmEdgeNoise.hash(h2)
            let h4 = FilmEdgeNoise.hash(h3), h5 = FilmEdgeNoise.hash(h4), h6 = FilmEdgeNoise.hash(h5)
            let u = FilmEdgeNoise.unit(h2) * 2 - 1
            var px = 0.0, py = 0.0, nx = 0.0, ny = 0.0
            switch h1 & 3 {
            case 0: px = u * hx; py = -hy; ny = 1
            case 1: px = u * hx; py = hy; ny = -1
            case 2: px = -hx; py = u * hy; nx = 1
            default: px = hx; py = u * hy; nx = -1
            }
            let size = FilmEdgeNoise.unit(h3), length = 0.3 + 1.8 * size * size
            let angle = (FilmEdgeNoise.unit(h4) - 0.5) * 2, curl = (FilmEdgeNoise.unit(h5) - 0.5) * 1.6
            let c = cos(angle), s = sin(angle)
            let dx = c * nx - s * ny, dy = s * nx + c * ny
            px -= 0.15 * nx; py -= 0.15 * ny
            // Cheap reject before walking the hair.
            guard abs(cx - px) < length + 0.3, abs(cy - py) < length + 0.3 else { continue }
            var nearest = Double.infinity
            var ax = px, ay = py
            for i in 1...8 {
                let q = Double(i) / 8
                let bx = px + (dx * q - dy * curl * q * q) * length
                let by = py + (dy * q + dx * curl * q * q) * length
                let ex = bx - ax, ey = by - ay
                let w = min(max(((cx - ax) * ex + (cy - ay) * ey) / max(ex * ex + ey * ey, 1e-12), 0), 1)
                nearest = min(nearest, hypot(cx - ax - w * ex, cy - ay - w * ey))
                ax = bx; ay = by
            }
            let width = 0.008 + 0.012 * FilmEdgeNoise.unit(h6), rr = max(width, 0.9 * blur)
            clear *= 1 - 0.85 * (width / rr) * FilmEdgeNoise.penumbra(nearest - rr, blur)
        }
        return 1 - clear
    }
    /// Light scattered by a filed carrier's bare edge falls on the paper just outside the
    /// opening: an imageless glow that fades the black border into the white margin.
    func carrierHalo(x: Int, y: Int) -> Double {
        guard distress.enlargerPrint else { return 0 }
        let d = carrierDistance(x: x, y: y)
        let r = max(distress.carrierBlur, pixelRadius)
        guard d > -r else { return 0 }
        return (1 - FilmEdgeNoise.penumbra(d, r)) * distress.carrierTail * exp(-max(d, 0) / distress.carrierTailWidth)
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
    /// Like real rail and sprocket wear they are long, thin, near-parallel and clustered in a few
    /// bands, mostly faint with an occasional strong one, and often broken into dashes.
    struct Scratch: Sendable { let across, slope, wander, wavelength, phase, start, end, width, depth, dash, bias: Double }
    static func scratches(_ d: FilmEdgeDistress, halfAlong ha: Double, halfAcross ht: Double, gateAcross: Double) -> [Scratch] {
        var b = streamSeed(d.seed, 19)
        func band() -> Double { b = FilmEdgeNoise.hash(b); return FilmEdgeNoise.unit(b) }
        let inner = gateAcross + 0.05, outer = max(inner + 0.05, ht - 0.03)
        let bands = (0..<4).map { _ in inner + (outer - inner) * band() }
        return (0..<scratchCount).map { k in
            var h = streamSeed(d.seed, UInt32(20 + k))
            func next() -> Double { h = FilmEdgeNoise.hash(h); return FilmEdgeNoise.unit(h) }
            let side: Double = next() < 0.5 ? -1 : 1
            let center = bands[Int(next() * 3.999)]
            let clustered = min(max(center + (next() * 2 - 1) * 0.15, inner), outer)
            // Draw both positions every time so toggling the clamp never shifts other features.
            let free = next(), anywhere = (next() * 2 - 1) * ht
            let across = d.scratchesInImage && free < 0.6 ? anywhere : side * clustered
            let slope = (next() * 2 - 1) * 0.0008
            let wander = 0.001 + 0.008 * next(), wavelength = 60 + 140 * next(), phase = next() * 6.2832
            let span = ha * (0.5 + 1.7 * next()), mid = (next() * 2 - 1) * ha
            let width = 0.004 + 0.016 * pow(next(), 1.3)
            let emulsion = next() < 0.25
            let depth = emulsion ? 0.05 + 0.6 * pow(next(), 2) : -(0.18 + 0.8 * pow(next(), 1.4))
            let dash = 0.6 + 6 * next(), bias = next() * 0.9 - 0.2
            return Scratch(across: across, slope: slope, wander: wander, wavelength: wavelength, phase: phase,
                           start: mid - span, end: mid + span, width: width, depth: depth, dash: dash, bias: bias)
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
            outside = 1 - FilmEdgeNoise.penumbra(gateDistance(fx, fy), pr)
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
            let pressure = FilmEdgeNoise.value(a / s.dash, Double(k) * 7.31, seed(30))
            let broken = min(max((pressure + s.bias) / 0.35, 0), 1)
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
    /// Rayleigh-like λ⁻⁴ relative to 450 nm: ≈0.23 at 650 nm, ≈0.45 at 550 nm.
    static let scatterWeights = SIMD3<Double>(0.23, 0.45, 1.0)
    var hasEmulsionScratches: Bool { distress.scratches > 0 && scratchCandidates.contains { $0.depth > 0 } }

    /// Combine intact film and clear light in transmission; never average densities with air.
    func transmit(_ film: SIMD3<Double>, clear: SIMD3<Double>, x: Int, y: Int, mode: Transmission) -> SIMD3<Double> {
        let support = supportCoverage(x: x, y: y, destination: mode.contains(.destination))
        let carrier = mode.contains(.carrier) ? carrierCoverage(x: x, y: y) : 1
        // Clear openings are the black reference wherever the carrier passes light.
        if mode.contains(.endpoint) { return film * (1 - carrier * (1 - support)) }
        var occlusion = SIMD3<Double>.zero
        if mode.contains(.damage) {
            let dust = dustOcclusion(x: x, y: y), scatter = scratchFields(x: x, y: y).scatter
            occlusion = 1 - (1 - dust) * (1 - scatter * Self.scatterWeights)
        }
        var light = (film * support + clear * (1 - support)) * (1 - occlusion * support) * carrier
        if mode.contains(.reflection) { light += clear * (carrierReflection(x: x, y: y) * carrier + carrierHalo(x: x, y: y)) }
        return light
    }
    /// Emulsion scratches thin the developed dye before printing or scanning.
    func scratchedDensity(_ density: SIMD3<Double>, x: Int, y: Int) -> SIMD3<Double> {
        density * (1 - scratchFields(x: x, y: y).removal)
    }

    /// Matches the Metal edge kernels. No full-frame mask bitmap is allocated.
    func uniforms(light: SIMD3<Double> = .zero, fogLight: SIMD3<Double> = .zero, coreLight: SIMD3<Double> = .zero) -> [SIMD4<Float>] {
        let d = distress
        let (gx, gy) = gateHalf
        let leak = leakFrame
        var values: [SIMD4<Float>] = [
            SIMD4(Float(width), Float(height), Float(millimetersPerPixel), portrait ? 1 : 0),
            SIMD4(Float(gx), Float(gy), Float(notched ? -gateCorner : gateCorner), Float(d.gateSoftness)),
            SIMD4(format == .film35 ? 1 : 0, Float(Self.holeCenter), Float(Self.holeRadius), d.scratchesInImage ? 1 : 0),
            SIMD4(Float(d.bulge), erodesGate ? 1 : 0, Float(cos(tiltRadians)), Float(sin(tiltRadians))),
            SIMD4(Float(d.seed & 0xffff), Float(d.seed >> 16), Float(stockHalf), Float(d.gateWear)),
            SIMD4(Float(d.carrierRoughness), Float(d.carrierTail), Float(carrierHalf.along), Float(carrierHalf.across)),
            SIMD4(Float(d.edgeFog), Float(d.fogDepth), Float(d.leak), Float(d.leakSize)),
            SIMD4(Float(leak.point.0), Float(leak.point.1), Float(leak.normal.0), Float(leak.normal.1)),
            SIMD4(Float(leak.offset), Float(leak.weight), Float(d.dust), Float(d.scratches)),
            SIMD4(Float(light.x), Float(light.y), Float(light.z), Float(d.carrierWave)),
            SIMD4(Float(perforation.rawValue), Float(perforation.pitch), Float(perforation.halfAlong), Float(perforation.halfAcross)),
            SIMD4(Float(d.carrierCorner), Float(Perforation.ks1870.pitch), Float(Perforation.ks1870.halfAlong), Float(Perforation.ks1870.halfAcross)),
            SIMD4(Float(d.holeVariation), Float(d.perforationLeak), d.leakKind == .front ? 1 : 0,
                  Float(FilmEdgeDistress.LeakShape.allCases.firstIndex(of: d.leakShape)!)),
            SIMD4(Float(fogLight.x), Float(fogLight.y), Float(fogLight.z), Float(d.carrierReflection)),
            SIMD4(Float(d.carrierBlur), Float(d.carrierDetail), Float(leak.direction.0), Float(leak.direction.1)),
            SIMD4(Float(coreLight.x), Float(coreLight.y), Float(coreLight.z), Float(d.enlargerPrint ? -d.carrierTailWidth : d.carrierTailWidth)),
            SIMD4(Float(easelOffset.x), Float(easelOffset.y), 0, 0),
        ]
        for s in scratchCandidates {
            values.append(SIMD4(Float(s.across), Float(s.wander), Float(s.wavelength), Float(s.phase)))
            values.append(SIMD4(Float(s.start), Float(s.end), Float(s.width), Float(s.depth)))
            values.append(SIMD4(Float(s.slope), Float(s.dash), Float(s.bias), 0))
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
    /// Right at the cut wall the piped light reaches the green layer as well, but not the blue
    /// top layer: a yellow core on a print or inverted scan.
    func coreLight(neutral: SIMD3<Double>) -> SIMD3<Double> { SIMD3(neutral.x, neutral.y * 0.75, neutral.z * 0.08) }
    var hasExposureNoise: Bool {
        distress.edgeFog > 0 || distress.leak > 0
            || (format == .film35 && (distress.perforationLeak > 0 || distress.holeVariation > 0))
    }
}

extension EditRecipe {
    /// The layout as rendered: a negative print is always an enlarger print on an easel; scans
    /// and cinema prints never are.
    nonisolated var renderedFilmEdgeLayout: FilmEdgeLayout? {
        guard var layout = filmEdgeLayout else { return nil }
        layout.distress.enlargerPrint = resolvedFilmEdgeType == .negativePrint
        return layout
    }
    /// The sheet this edit is printed on, or nil when the picture is shown as itself. A film-edge
    /// enlarger print always has one: the easel's border is part of it.
    nonisolated var printedLayout: PrintLayout? {
        if renderedFilmEdgeLayout?.distress.enlargerPrint == true { return printLayout ?? PrintLayout() }
        return printLayout.flatMap { $0.isIdentity ? nil : $0 }
    }
    /// What goes on the sheet, for a picture or film-edge canvas of `size`.
    nonisolated func printContent(canvas size: CGSize) -> PrintGeometry.Content {
        guard let layout = renderedFilmEdgeLayout else { return .picture }
        return layout.distress.enlargerPrint ? .enlarger(frame: layout.easelFrame(canvas: size)) : .scan
    }
    /// Normalize old adaptive v5 recipes as well as live crop edits. Never mutate Develop.
    nonisolated mutating func constrainFilmEdgeCrop(imageSize: CGSize) {
        guard let filmEdgeLayout else { return }
        let upright = geometry.quarterTurns % 2 == 0 ? imageSize
            : CGSize(width: imageSize.height, height: imageSize.width)
        crop = filmEdgeLayout.constrainedCrop(crop, imageSize: upright)
    }
}
