// Synthetic test charts for film-edge, LUT and loupe checks. No real photographs.
//   swift Scripts/make-test-images.swift [output folder]   (default /private/tmp/spektrafilm-build/test-images)
// Each chart answers one question; the file name says which.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
                 : "/private/tmp/spektrafilm-build/test-images")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// sRGB-encoded value for a scene-linear reflectance (18 % grey → 0.46).
func encode(_ linear: Double) -> Double {
    let v = min(max(linear, 0), 1)
    return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
}
func color(_ r: Double, _ g: Double, _ b: Double) -> CGColor { CGColor(colorSpace: sRGB, components: [r, g, b, 1])! }
func grey(_ linear: Double) -> CGColor { let v = encode(linear); return color(v, v, v) }

func chart(_ name: String, _ width: Int, _ height: Int, _ draw: (CGContext, CGFloat, CGFloat) -> Void) throws {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Top-left origin, so every chart reads the way it is drawn.
    context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
    draw(context, CGFloat(width), CGFloat(height))
    let url = output.appendingPathComponent(name + ".jpg")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    print(url.path)
}

func text(_ c: CGContext, _ string: String, at p: CGPoint, size: CGFloat, color fill: CGColor) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let attributed = NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill])
    let line = CTLineCreateWithAttributedString(attributed)
    c.saveGState()
    c.translateBy(x: p.x, y: p.y); c.scaleBy(x: 1, y: -1)  // CoreText draws y-up
    c.textPosition = .zero
    CTLineDraw(line, c)
    c.restoreGState()
}

/// Orientation marks: "TOP" with an arrow, and an asymmetric F that reveals any mirror.
func orientation(_ c: CGContext, _ w: CGFloat, _ h: CGFloat, ink: CGColor,
                 top: CGFloat = 0.2, mark: CGPoint? = nil) {
    let s = min(w, h)
    text(c, "TOP ↑", at: CGPoint(x: w / 2 - s * 0.06, y: s * top), size: s * 0.04, color: ink)
    c.setFillColor(ink)
    let u = s * 0.012, x = mark?.x ?? w * 0.5 + s * 0.12, y = mark?.y ?? h * 0.5 + s * 0.1
    c.fill(CGRect(x: x, y: y, width: u, height: 6 * u))
    c.fill(CGRect(x: x, y: y, width: 4 * u, height: u))
    c.fill(CGRect(x: x, y: y + 2.5 * u, width: 3 * u, height: u))
}
func crosshair(_ c: CGContext, _ w: CGFloat, _ h: CGFloat, ink: CGColor) {
    let s = min(w, h)
    c.setStrokeColor(ink); c.setLineWidth(max(2, s / 1000))
    c.strokeLineSegments(between: [CGPoint(x: w / 2 - s * 0.05, y: h / 2), CGPoint(x: w / 2 + s * 0.05, y: h / 2),
                                   CGPoint(x: w / 2, y: h / 2 - s * 0.05), CGPoint(x: w / 2, y: h / 2 + s * 0.05)])
    c.strokeEllipse(in: CGRect(x: w / 2 - s * 0.03, y: h / 2 - s * 0.03, width: s * 0.06, height: s * 0.06))
}

/// Bands of saturated and neutral patches touching every border, with a hairline exactly at the
/// edge that is white along one half of each side and black along the other.
func edgeBands(_ c: CGContext, _ w: CGFloat, _ h: CGFloat) {
    let palette = [grey(0.9), grey(0.003), color(0.85, 0.1, 0.1), color(0.1, 0.7, 0.2), color(0.1, 0.25, 0.85),
                   color(0.95, 0.85, 0.1), grey(0.18), color(0.95, 0.6, 0.45), color(0.1, 0.7, 0.75)]
    let band = min(w, h) * 0.07
    func side(_ length: CGFloat, _ rect: (CGFloat, CGFloat) -> CGRect) {
        var start: CGFloat = 0, i = 0
        while start < length {
            let size = length * (i % 3 == 0 ? 0.09 : 0.055)
            c.setFillColor(palette[i % palette.count]); c.fill(rect(start, min(size, length - start)))
            start += size; i += 1
        }
    }
    side(w) { CGRect(x: $0, y: 0, width: $1, height: band) }
    side(w) { CGRect(x: w - $0 - $1, y: h - band, width: $1, height: band) }
    side(h) { CGRect(x: 0, y: h - $0 - $1, width: band, height: $1) }
    side(h) { CGRect(x: w - band, y: $0, width: band, height: $1) }
    let line = max(2, min(w, h) / 1500)
    for (rect, white) in [(CGRect(x: 0, y: 0, width: w / 2, height: line), true), (CGRect(x: w / 2, y: 0, width: w / 2, height: line), false),
                          (CGRect(x: 0, y: h - line, width: w / 2, height: line), false), (CGRect(x: w / 2, y: h - line, width: w / 2, height: line), true),
                          (CGRect(x: 0, y: 0, width: line, height: h / 2), false), (CGRect(x: 0, y: h / 2, width: line, height: h / 2), true),
                          (CGRect(x: w - line, y: 0, width: line, height: h / 2), true), (CGRect(x: w - line, y: h / 2, width: line, height: h / 2), false)] {
        c.setFillColor(white ? grey(1) : grey(0)); c.fill(rect)
    }
}

// 01 — Does the gate edge leave a rim or seam on bright, dark and coloured picture content?
try chart("01-gate-edges", 6000, 4000) { c, w, h in
    c.setFillColor(grey(0.18)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    edgeBands(c, w, h)
    crosshair(c, w, h, ink: grey(0.9)); orientation(c, w, h, ink: grey(0.9))
}

// 02 — Tone and colour: Spektrafilm vs LUT vs Develop off, and how leaks lift each tone.
try chart("02-step-wedge", 6000, 4000) { c, w, h in
    c.setFillColor(grey(0.18)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    // 21 steps, half a stop apart, from 6.6 stops under to 3.4 over mid grey.
    let steps = 21, top = h * 0.12, stepH = h * 0.22, margin = w * 0.04
    let stepW = (w - 2 * margin) / CGFloat(steps)
    for i in 0..<steps {
        c.setFillColor(grey(0.18 * pow(2, Double(i - 13) / 2)))
        c.fill(CGRect(x: margin + CGFloat(i) * stepW, y: top, width: stepW + 1, height: stepH))
    }
    // Smooth linear-light ramp for banding and shoulder checks.
    let ramp = CGGradient(colorsSpace: sRGB, colors: (0...32).map { grey(Double($0) / 32 * Double($0) / 32) } as CFArray, locations: nil)!
    c.saveGState(); c.clip(to: CGRect(x: margin, y: top + stepH + h * 0.03, width: w - 2 * margin, height: h * 0.08))
    c.drawLinearGradient(ramp, start: CGPoint(x: margin, y: 0), end: CGPoint(x: w - margin, y: 0), options: []); c.restoreGState()
    // 24 colour patches with published sRGB values of the common 24-patch colour checker.
    let patches: [(Double, Double, Double)] = [
        (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
        (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
        (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
        (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52)]
    let gridTop = top + stepH + h * 0.15, cell = min((w - 2 * margin) / 6, (h - gridTop - h * 0.05) / 4)
    let gridLeft = (w - 6 * cell) / 2
    for (i, p) in patches.enumerated() {
        c.setFillColor(color(p.0 / 255, p.1 / 255, p.2 / 255))
        c.fill(CGRect(x: gridLeft + CGFloat(i % 6) * cell + cell * 0.06, y: gridTop + CGFloat(i / 6) * cell + cell * 0.06,
                      width: cell * 0.88, height: cell * 0.88))
    }
    orientation(c, w, h, ink: grey(0.9), top: 0.08, mark: CGPoint(x: w * 0.88, y: h * 0.7))
}

// 03 — Night: leaks, edge fog, hole rims and dust read best over deep shadows.
try chart("03-night", 6000, 4000) { c, w, h in
    let sky = CGGradient(colorsSpace: sRGB, colors: [grey(0.001), color(0.05, 0.06, 0.12), color(0.02, 0.02, 0.025)] as CFArray,
                         locations: [0, 0.62, 1])!
    c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: h), options: [])
    var seed: UInt64 = 7
    func random() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
    for _ in 0..<14 {  // street lamps along a horizon, with a soft glow
        let p = CGPoint(x: w * (0.08 + 0.84 * random()), y: h * (0.6 + 0.08 * random())), r = min(w, h) * (0.004 + 0.006 * random())
        let glow = CGGradient(colorsSpace: sRGB, colors: [color(1, 0.85, 0.55), color(1, 0.6, 0.25).copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        c.drawRadialGradient(glow, startCenter: p, startRadius: r, endCenter: p, endRadius: r * 9, options: [])
        c.setFillColor(color(1, 0.97, 0.9)); c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }
    for _ in 0..<60 { c.setFillColor(grey(0.4 + 0.5 * Double(random())))
        let p = CGPoint(x: w * random(), y: h * 0.5 * random()); c.fill(CGRect(x: p.x, y: p.y, width: 3, height: 3)) }
}

// 04 — Overcast high key: dust and scratches in scans, and any white rim at a soft gate.
try chart("04-overcast", 6000, 4000) { c, w, h in
    let sky = CGGradient(colorsSpace: sRGB, colors: [grey(0.85), grey(0.7)] as CFArray, locations: nil)!
    c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: h), options: [])
    c.setStrokeColor(grey(0.02)); c.setLineCap(.round)
    func branch(_ p: CGPoint, _ angle: CGFloat, _ length: CGFloat, _ width: CGFloat, _ depth: Int) {
        guard depth > 0 else { return }
        let q = CGPoint(x: p.x + cos(angle) * length, y: p.y + sin(angle) * length)
        c.setLineWidth(width); c.strokeLineSegments(between: [p, q])
        branch(q, angle - 0.42, length * 0.72, width * 0.65, depth - 1)
        branch(q, angle + 0.33, length * 0.68, width * 0.62, depth - 1)
    }
    branch(CGPoint(x: w * 0.78, y: h), -.pi / 2 - 0.15, h * 0.28, w * 0.012, 9)
    c.setFillColor(grey(0.05)); c.fill(CGRect(x: 0, y: h * 0.93, width: w, height: h * 0.07))
}

// 05 — Grid, portrait: tilt, bulge, centre alignment and native-pixel loupe checks.
try chart("05-grid-portrait", 4000, 6000) { c, w, h in
    c.setFillColor(grey(0.75)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let pitch = w / 24  // ≈ 1 mm of a 24 mm-wide gate
    c.setStrokeColor(grey(0.01))
    var x: CGFloat = 0
    var i = 0
    while x <= w { c.setLineWidth(i % 6 == 0 ? 6 : 2); c.strokeLineSegments(between: [CGPoint(x: x, y: 0), CGPoint(x: x, y: h)]); x += pitch; i += 1 }
    var y: CGFloat = 0; i = 0
    while y <= h { c.setLineWidth(i % 6 == 0 ? 6 : 2); c.strokeLineSegments(between: [CGPoint(x: 0, y: y), CGPoint(x: w, y: y)]); y += pitch; i += 1 }
    // One-pixel line pairs at the centre and near each corner for the 100 % loupe.
    for (cx, cy) in [(w / 2, h / 2), (w * 0.12, h * 0.08), (w * 0.88, h * 0.92)] {
        for k in 0..<40 { c.setFillColor(k % 2 == 0 ? grey(0) : grey(1))
            c.fill(CGRect(x: cx - 40 + CGFloat(k) * 2, y: cy - 40, width: 2, height: 80)) }
    }
    crosshair(c, w, h, ink: color(0.85, 0.1, 0.1)); orientation(c, w, h, ink: color(0.85, 0.1, 0.1))
}

// 06 — Square for 120: the same edge bands on a 1:1 frame.
try chart("06-square-120", 5000, 5000) { c, w, h in
    c.setFillColor(grey(0.18)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    edgeBands(c, w, h)
    crosshair(c, w, h, ink: grey(0.9)); orientation(c, w, h, ink: grey(0.9))
}

// 07 — Flat 18 % grey: leak and fog shape, continuity across the gate, grain.
try chart("07-flat-grey", 6000, 4000) { c, w, h in
    c.setFillColor(grey(0.18)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
}

// 08 — Fine detail: Siemens stars at the centre and corners for sharpness, halation and the loupe.
try chart("08-fine-detail", 6000, 4000) { c, w, h in
    c.setFillColor(grey(0.5)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    func star(_ p: CGPoint, _ r: CGFloat) {
        c.setFillColor(grey(1)); c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        c.setFillColor(grey(0))
        for k in 0..<36 {
            let a0 = CGFloat(k) * .pi / 18, a1 = a0 + .pi / 36
            c.move(to: p); c.addArc(center: p, radius: r, startAngle: a0, endAngle: a1, clockwise: false); c.closePath(); c.fillPath()
        }
    }
    let s = min(w, h)
    star(CGPoint(x: w / 2, y: h / 2), s * 0.22)
    for (x, y) in [(0.09, 0.13), (0.91, 0.13), (0.09, 0.87), (0.91, 0.87)] { star(CGPoint(x: w * x, y: h * y), s * 0.08) }
    orientation(c, w, h, ink: grey(1), top: 0.12, mark: CGPoint(x: w * 0.7, y: h * 0.4))
}
