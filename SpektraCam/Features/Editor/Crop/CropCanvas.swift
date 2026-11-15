import SwiftUI
import UIKit

/// Maps screen gestures onto the upright source's normalized crop rectangle.
struct CropCanvas: View {
    let image: UIImage
    @Binding var selection: CropSelection
    @Binding var geometry: ImageGeometry
    @GestureState private var framingOrigin: CGSize?
    @GestureState private var dragOrigin: CGRect?

    private var imageAspect: CGFloat { image.size.width / image.size.height }

    var body: some View {
        GeometryReader { proxy in
            let frame = fittedImage(in: proxy.size)
            let crop = CGRect(
                x: frame.minX + selection.normalizedRect.minX * frame.width,
                y: frame.minY + selection.normalizedRect.minY * frame.height,
                width: selection.normalizedRect.width * frame.width,
                height: selection.normalizedRect.height * frame.height
            )

            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .accessibilityHidden(true)

                Path { path in
                    path.addRect(frame)
                    path.addRect(crop)
                }
                .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                cropGrid(in: crop)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                Rectangle().fill(.clear)
                    .frame(width: crop.width, height: crop.height)
                    .contentShape(.rect)
                    .position(x: crop.midX, y: crop.midY)
                    .gesture(moveGesture(in: frame.size))
                    .accessibilityElement()
                    .accessibilityLabel(
                        String(localized: "crop.area", defaultValue: "Crop area")
                    )
                    .accessibilityValue(cropDescription)
                    .accessibilityIdentifier("crop.area")
                    .accessibilityAction(
                        named: String(localized: "crop.move_left", defaultValue: "Move left")
                    ) { moveBy(x: -0.02, y: 0) }
                    .accessibilityAction(
                        named: String(
                            localized: "crop.move_right", defaultValue: "Move right")
                    ) { moveBy(x: 0.02, y: 0) }
                    .accessibilityAction(
                        named: String(localized: "crop.move_up", defaultValue: "Move up")
                    ) { moveBy(x: 0, y: -0.02) }
                    .accessibilityAction(
                        named: String(localized: "crop.move_down", defaultValue: "Move down")
                    ) { moveBy(x: 0, y: 0.02) }

                ForEach(CropCorner.allCases) { corner in
                    let point = corner.position(in: crop)
                    Circle().fill(.white)
                        .frame(width: 12, height: 12)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                        .position(point)
                        .gesture(resizeGesture(corner, in: frame.size))
                        .accessibilityElement()
                        .accessibilityLabel(corner.title)
                        .accessibilityValue(cropDescription)
                        .accessibilityIdentifier("crop.handle.\(corner.rawValue)")
                        .accessibilityAdjustableAction { direction in
                            let step: CGFloat = direction == .increment ? 0.02 : -0.02
                            selection.resize(
                                from: selection.normalizedRect, corner: corner,
                                by: CGSize(
                                    width: corner.isLeft ? -step : step,
                                    height: corner.isTop ? -step : step),
                                imageAspect: imageAspect
                            )
                        }
                }
            }
            .coordinateSpace(name: "cropCanvas")
        }
    }

    private var cropDescription: String {
        String(
            localized: "crop.area_summary",
            defaultValue:
                "\(Int(selection.normalizedRect.width * 100)) percent wide, \(Int(selection.normalizedRect.height * 100)) percent high; framing \(Int(geometry.framingX * 100)), \(Int(geometry.framingY * 100))"
        )
    }

    private func fittedImage(in size: CGSize) -> CGRect {
        let available = CGSize(width: max(1, size.width - 48), height: max(1, size.height - 48))
        let scale = min(available.width / image.size.width, available.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(
            x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height)
    }

    private func cropGrid(in rect: CGRect) -> some View {
        Path { path in
            path.addRect(rect)
            for third in 1...2 {
                let x = rect.minX + rect.width * CGFloat(third) / 3
                let y = rect.minY + rect.height * CGFloat(third) / 3
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(.white.opacity(0.85), lineWidth: 1)
    }

    private func moveGesture(in size: CGSize) -> some Gesture {
        DragGesture(coordinateSpace: .named("cropCanvas"))
            .updating($dragOrigin) { _, origin, _ in
                if origin == nil { origin = selection.normalizedRect }
            }
            .updating($framingOrigin) { _, origin, _ in
                if origin == nil {
                    let position = geometry.boundedFraming(in: image.size)
                    origin = CGSize(width: position.x, height: position.y)
                }
            }
            .onChanged { value in
                if geometry.straightenDegrees != 0
                    && selection.normalizedRect == CropSelection.fullImage
                {
                    let start =
                        framingOrigin ?? CGSize(width: geometry.framingX, height: geometry.framingY)
                    var requested = geometry
                    requested.framingX = start.width + value.translation.width / size.width
                    requested.framingY = start.height + value.translation.height / size.height
                    let position = requested.boundedFraming(in: image.size)
                    geometry.framingX = position.x
                    geometry.framingY = position.y
                } else {
                    selection.move(
                        from: dragOrigin ?? selection.normalizedRect,
                        by: CGSize(
                            width: value.translation.width / size.width,
                            height: value.translation.height / size.height))
                }

            }
    }

    private func resizeGesture(_ corner: CropCorner, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("cropCanvas"))
            .updating($dragOrigin) { _, origin, _ in
                if origin == nil { origin = selection.normalizedRect }
            }
            .onChanged { value in
                selection.resize(
                    from: dragOrigin ?? selection.normalizedRect, corner: corner,
                    by: CGSize(
                        width: value.translation.width / size.width,
                        height: value.translation.height / size.height),
                    imageAspect: imageAspect)
            }
    }

    private func moveBy(x: CGFloat, y: CGFloat) {
        selection.move(from: selection.normalizedRect, by: CGSize(width: x, height: y))
    }
}
