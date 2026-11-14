import SwiftUI
import UIKit

/// A photographer's loupe resting on the print. It shows the photograph at 100 % of the
/// rendered pixels (double-tap for 200 %), from a full-resolution frame when one is ready.
/// Drag it anywhere over the light table; it starts in the upper right.
struct DarkroomLoupe: View {
    /// The best available pixels for the photograph and where it sits on screen.
    let image: UIImage
    let imageFrame: CGRect
    let paperFrame: CGRect
    let bounds: CGSize
    var refining = false
    /// The table beside the print, so the lens shows what is really under it.
    var surround = Color(white: 0.86)
    var paper = Color.white
    /// Pixel width of the full-resolution frame. Magnification is fixed to it, so the view
    /// only sharpens when that frame replaces the preview; it never changes scale.
    var fullWidth: CGFloat? = nil
    /// Native-resolution pixels for the area under the lens, when they have been rendered.
    var patch: PhotoRenderer.Detail? = nil
    /// A clean print's easel-blade penumbra, as a fraction of the picture's width.
    var bladeEdge: CGFloat = 0
    /// Reports the part of the photograph under the lens (unit coordinates of `imageFrame`).
    var onInspect: ((CGRect) -> Void)? = nil
    @Binding var center: CGPoint?
    @State private var widest: CGFloat = 0
    @State private var doubled = false
    @State private var dragOrigin: CGPoint?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let diameter: CGFloat = 156
    private let rim: CGFloat = 9

    private var resolvedCenter: CGPoint {
        let r = Self.diameter / 2
        let fallback = CGPoint(x: bounds.width - r - 10, y: r + 10)
        let c = center ?? fallback
        return CGPoint(x: min(max(c.x, 0), bounds.width), y: min(max(c.y, 0), bounds.height))
    }
    private var inspected: CGRect {
        let c = resolvedCenter, half = Self.diameter / 2 / zoom
        let w = max(imageFrame.width, 1), h = max(imageFrame.height, 1)
        return CGRect(x: (c.x - half - imageFrame.minX) / w, y: (c.y - half - imageFrame.minY) / h,
                      width: 2 * half / w, height: 2 * half / h)
    }
    private var pixelWidth: CGFloat {
        CGFloat(image.cgImage?.width ?? Int(image.size.width * image.scale))
    }
    /// Loupe points per screen point, so one rendered pixel covers one device pixel at 100 %.
    private var zoom: CGFloat {
        let native = max(fullWidth ?? 0, widest, pixelWidth) / max(imageFrame.width, 1) / displayScale
        return max(native, 1.5) * (doubled ? 2 : 1)
    }

    var body: some View {
        let c = resolvedCenter, z = zoom, d = Self.diameter
        let offset = { (p: CGPoint) in CGPoint(x: d / 2 + (p.x - c.x) * z, y: d / 2 + (p.y - c.y) * z) }
        let paperOrigin = offset(paperFrame.origin), imageOrigin = offset(imageFrame.origin)
        ZStack {
            ZStack(alignment: .topLeading) {
                surround
                Rectangle().fill(paper)
                    .frame(width: paperFrame.width * z, height: paperFrame.height * z)
                    .offset(x: paperOrigin.x, y: paperOrigin.y)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image).resizable().interpolation(.high)
                        .frame(width: imageFrame.width * z, height: imageFrame.height * z)
                    if let patch {
                        Image(decorative: patch.image, scale: 1).resizable().interpolation(.high)
                            .frame(width: patch.rect.width * imageFrame.width * z,
                                   height: patch.rect.height * imageFrame.height * z)
                            .offset(x: patch.rect.minX * imageFrame.width * z,
                                    y: patch.rect.minY * imageFrame.height * z)
                    }
                }
                .frame(width: imageFrame.width * z, height: imageFrame.height * z, alignment: .topLeading)
                .modifier(BladeEdge(width: bladeEdge * imageFrame.width * z))
                .offset(x: imageOrigin.x, y: imageOrigin.y)
            }
            .frame(width: d, height: d, alignment: .topLeading)
            .clipShape(Circle())
            // Lens: a soft vignette toward the barrel and a glancing highlight on the glass.
            Circle().fill(RadialGradient(colors: [.clear, .clear, .black.opacity(0.28)],
                                         center: .center, startRadius: 0, endRadius: d / 2))
            // The reflection of an overhead lamp: centred on the glass and held inside the barrel.
            Ellipse().fill(LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0)],
                                          startPoint: .top, endPoint: .bottom))
                .frame(width: d * 0.66, height: d * 0.34).offset(y: -d * 0.24)
                .blendMode(.screen)
                .mask(Circle().inset(by: rim))
            // Barrel: brushed dark metal with a bright bevel.
            Circle().strokeBorder(AngularGradient(colors: [Color(white: 0.16), Color(white: 0.55), Color(white: 0.2),
                                                           Color(white: 0.42), Color(white: 0.14), Color(white: 0.16)],
                                                  center: .center), lineWidth: rim)
            Circle().inset(by: rim).strokeBorder(Color.black.opacity(0.65), lineWidth: 1)
            Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75)
            VStack {
                Spacer()
                HStack(spacing: 4) {
                    if refining { ProgressView().controlSize(.mini).tint(.white) }
                    Text(verbatim: doubled ? "200 %" : "100 %")
                }
                .font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(.bottom, rim + 4)
            }
        }
        .frame(width: d, height: d)
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 6)
        .contentShape(Circle())
        .position(c)
        .onChange(of: pixelWidth, initial: true) { _, width in widest = max(widest, width) }
        .onChange(of: inspected, initial: true) { _, rect in onInspect?(rect) }
        .onChange(of: imageFrame.width / max(imageFrame.height, 1)) { widest = pixelWidth }
        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
            let start = dragOrigin ?? c
            if dragOrigin == nil { dragOrigin = start }
            center = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
        }.onEnded { _ in dragOrigin = nil })
        .onTapGesture(count: 2) {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { doubled.toggle() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "darkroom.loupe", defaultValue: "Loupe"))
        .accessibilityValue(doubled ? "200 %" : "100 %")
        .accessibilityHint(String(localized: "darkroom.loupe_hint", defaultValue: "Drag over the print to inspect it. Double-tap to change magnification."))
        .accessibilityAction(named: String(localized: "darkroom.loupe_zoom", defaultValue: "Change magnification")) { doubled.toggle() }
        .accessibilityIdentifier("darkroom.loupe")
    }
}

/// The easel blade's penumbra on a clean print (see `Easel`): the picture fades to paper across it.
struct BladeEdge: ViewModifier {
    let width: CGFloat
    func body(content: Content) -> some View {
        if width > 0.3 {
            content.mask { Rectangle().inset(by: width / 2).blur(radius: width / 4) }
        } else {
            content
        }
    }
}
