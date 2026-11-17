import SwiftUI

/// Shared native pills for Develop, Adjust, Effects and Darkroom.
struct PanelTabs<Selection: Hashable & RawRepresentable>: View
where Selection.RawValue == String {
    let options: [(Selection, String)]
    @Binding var selection: Selection
    let prefix: String
    var isSelectionActive = true
    var unavailable: Set<Selection> = []

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(options, id: \.0) { option in
                    Group {
                        if isSelectionActive && selection == option.0 {
                            tab(option).buttonStyle(.glassProminent).foregroundStyle(.white)
                        } else {
                            tab(option).buttonStyle(.glass)
                        }
                    }
                    .accessibilityIdentifier(prefix + option.0.rawValue)
                    .accessibilityAddTraits(isSelectionActive && selection == option.0 ? .isSelected : [])
                    .disabled(unavailable.contains(option.0))
                }
            }.padding(.vertical, 4)
        }.scrollIndicators(.hidden).frame(height: 44)
            .dynamicTypeSize(...DynamicTypeSize.large)
    }
    private func tab(_ option: (Selection, String)) -> some View {
        Button(option.1) { selection = option.0 }
            .tint(isSelectionActive ? Color.accentColor : Color.secondary)
            .font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
            .frame(minHeight: 38)
            .accessibilityShowsLargeContentViewer { Text(option.1) }
    }
}

struct PanelExpansionButton: View {
    @Binding var expanded: Bool
    let identifier: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(
            expanded
                ? String(localized: "editor.collapse_panel", defaultValue: "Collapse Panel")
                : String(localized: "editor.expand_panel", defaultValue: "Expand Panel"),
            systemImage: expanded ? "chevron.down" : "chevron.up"
        ) {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { expanded.toggle() }
        }
        .glassIconButton()
        .accessibilityIdentifier(identifier)
        .accessibilityValue(
            expanded
                ? String(localized: "common.expanded", defaultValue: "Expanded")
                : String(localized: "common.collapsed", defaultValue: "Collapsed"))
    }
}

extension View {
    /// A round glass button showing only its icon, with the minimum touch target.
    func glassIconButton() -> some View {
        labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
            .frame(minWidth: 44, minHeight: 44)
    }
}
