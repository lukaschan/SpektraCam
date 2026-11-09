import SwiftUI

/// A switch keeps its native size; narrow columns and large text use a separate label row.
struct AdaptiveToggle: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var availableWidth: CGFloat = 0
    var body: some View {
        Group {
            if availableWidth >= 240 && !typeSize.isAccessibilitySize {
                Toggle(title, isOn: $isOn).fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                    Toggle(title, isOn: $isOn).labelsHidden().padding(.trailing, 8)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

}
struct ImportProgress: View {
    let text: String
    var body: some View { ProgressView(text).padding().background(.regularMaterial, in: .capsule) }
}
