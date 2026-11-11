import SwiftUI

/// A static fluorescent-era diffuser and enamel rim, drawn only at viewport size.
struct LightTableBackdrop: View {
    var body: some View {
        Canvas(opaque: true) { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(bounds), with: .color(Color(white: 0.69)))
            let rim = bounds.insetBy(dx: 7, dy: 7)
            context.fill(
                Path(roundedRect: rim, cornerRadius: 16),
                with: .linearGradient(
                    Gradient(colors: [Color(white: 0.83), Color(white: 0.66)]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            let face = rim.insetBy(dx: 9, dy: 9)
            context.fill(
                Path(roundedRect: face, cornerRadius: 8),
                with: .radialGradient(
                    Gradient(colors: [Color(white: 0.96), Color(white: 0.86)]),
                    center: CGPoint(x: face.midX, y: face.height * 0.42),
                    startRadius: 0, endRadius: max(size.width, size.height) * 0.72))
            context.stroke(
                Path(roundedRect: face, cornerRadius: 8),
                with: .color(.black.opacity(0.2)), lineWidth: 1)
            context.stroke(
                Path(roundedRect: rim.insetBy(dx: 1, dy: 1), cornerRadius: 15),
                with: .color(.white.opacity(0.38)), lineWidth: 1)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
