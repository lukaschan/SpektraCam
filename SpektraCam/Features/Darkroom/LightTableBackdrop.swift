import SwiftUI
import UIKit

/// A fluorescent-tube light box: enamelled steel frame, opal diffuser, tubes showing faintly
/// through it. Switched off, the diffuser is a dim neutral surround for judging the print
/// the way it will be seen away from the table. Static; drawn only at viewport size.
struct LightTableBackdrop: View {
    var lit = true
    /// The diffuser's tone beside the print, for views that repeat the table (the loupe).
    static func surround(lit: Bool) -> Color { Color(white: lit ? 0.9 : 0.46) }

    var body: some View {
        Canvas(opaque: true) { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            // Hammered grey-green enamel, lighter where the room light catches the top edge.
            context.fill(
                Path(bounds),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.60, green: 0.63, blue: 0.60), Color(red: 0.47, green: 0.50, blue: 0.48),
                    ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let well = bounds.insetBy(dx: 9, dy: 9)
            // The diffuser sits in a shallow well: dark on the upper lip, bright on the lower.
            context.fill(Path(roundedRect: well.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 11),
                         with: .linearGradient(
                            Gradient(colors: [.black.opacity(0.45), .white.opacity(0.35)]),
                            startPoint: CGPoint(x: 0, y: well.minY), endPoint: CGPoint(x: 0, y: well.maxY)))
            let face = Path(roundedRect: well, cornerRadius: 10)
            if lit {
                context.fill(face, with: .color(Color(red: 0.90, green: 0.905, blue: 0.895)))
                // Two tubes run across the box; opal acrylic spreads each into a broad soft band.
                context.drawLayer { layer in
                    layer.clip(to: face)
                    for centre in [0.3, 0.7] {
                        let y = well.minY + well.height * centre, reach = well.height * 0.3
                        layer.fill(
                            Path(CGRect(x: well.minX, y: y - reach, width: well.width, height: 2 * reach)),
                            with: .linearGradient(
                                Gradient(stops: [
                                    .init(color: .white.opacity(0), location: 0),
                                    .init(color: .white.opacity(0.55), location: 0.5),
                                    .init(color: .white.opacity(0), location: 1),
                                ]), startPoint: CGPoint(x: 0, y: y - reach),
                                endPoint: CGPoint(x: 0, y: y + reach)))
                    }
                    // Tube ends are dimmer; the box falls off toward its short sides.
                    layer.fill(
                        face,
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: .black.opacity(0.10), location: 0),
                                .init(color: .black.opacity(0), location: 0.14),
                                .init(color: .black.opacity(0), location: 0.86),
                                .init(color: .black.opacity(0.10), location: 1),
                            ]), startPoint: CGPoint(x: well.minX, y: 0),
                            endPoint: CGPoint(x: well.maxX, y: 0)))
                }
            } else {
                // Unlit opal reflects the room: a flat, slightly cool mid grey.
                context.fill(
                    face,
                    with: .linearGradient(
                        Gradient(colors: [Color(white: 0.49), Color(white: 0.43)]),
                        startPoint: CGPoint(x: 0, y: well.minY), endPoint: CGPoint(x: 0, y: well.maxY)))
            }
            context.stroke(face, with: .color(.black.opacity(0.28)), lineWidth: 1)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// The light box's own rocker switch, set into the frame.
struct LightTableSwitch: View {
    @Binding var lit: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { lit.toggle() }
        } label: {
            ZStack {
                // Bezel recessed into the enamel.
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.12))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.25), lineWidth: 0.75))
                // The rocker: the pressed half is in shade, the raised half catches light.
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(
                        colors: lit ? [Color(white: 0.20), Color(white: 0.46)] : [Color(white: 0.46), Color(white: 0.20)],
                        startPoint: .top, endPoint: .bottom))
                    .padding(3)
                VStack(spacing: 9) {
                    Rectangle().fill(.white.opacity(lit ? 0.9 : 0.45)).frame(width: 1.5, height: 8)
                    Circle().strokeBorder(.white.opacity(lit ? 0.45 : 0.9), lineWidth: 1.5).frame(width: 8, height: 8)
                }
                // Neon indicator of the era, lit with the tubes.
                Circle().fill(lit ? Color(red: 1, green: 0.42, blue: 0.2) : Color(red: 0.32, green: 0.12, blue: 0.08))
                    .frame(width: 4, height: 4)
                    .shadow(color: lit ? Color(red: 1, green: 0.4, blue: 0.2).opacity(0.9) : .clear, radius: 3)
            }
            .frame(width: 26, height: 44)
            .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: lit)
        .accessibilityLabel(String(localized: "darkroom.light_table", defaultValue: "Light table"))
        .accessibilityValue(lit ? String(localized: "common.on", defaultValue: "On") : String(localized: "common.off", defaultValue: "Off"))
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier("darkroom.light.switch")
    }
}

/// Paper colour for the sheet under a hand print, remembered per rendered frame.
@MainActor enum PaperTone {
    private static let cache = NSCache<UIImage, UIColor>()
    static func color(of image: UIImage) -> Color {
        if let hit = cache.object(forKey: image) { return Color(uiColor: hit) }
        guard let cg = image.cgImage else { return .white }
        let tone = UIColor(cgColor: PrintCompositor.paperTone(of: cg))
        cache.setObject(tone, forKey: image)
        return Color(uiColor: tone)
    }
}
