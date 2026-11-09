import SwiftUI

/// Exposure remains reachable without moving the focus point or waiting for a focus overlay.
struct CameraExposureControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max").accessibilityHidden(true)
            DefaultSlider(value: $value, range: range, defaultValue: 0,
                title: String(localized: "camera_preview.camera_exposure", defaultValue: "Camera exposure"),
                identifier: "camera.exposure", fillOrigin: 0)
                .accessibilityValue(String(format: "%+.2f EV", value))
            Button { value = 0 } label: {
                Text(String(format: "%+.2f EV", value))
                    .monospacedDigit().frame(width: 76, height: 44, alignment: .trailing).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "control.reset_to_default", defaultValue: "Reset to Default"))
            .accessibilityValue(String(format: "%+.2f EV", value))
            .accessibilityIdentifier("camera.exposureReset")
        }
        .font(.footnote).foregroundStyle(.white).frame(minHeight: 44)
    }
}

#if DEBUG
/// Isolated control fixture; no camera permission or photo library is opened.
struct CameraExposureControlPreview: View {
    @State private var exposure = 0.0
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraExposureControl(value: $exposure, range: -3...3).frame(width: 320)
        }
    }
}
#endif
