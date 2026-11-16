import SwiftUI
import UIKit

/// The interface tint chosen in About. Stored by name, so adding a choice never changes
/// what a saved one means. Magenta is the asset-catalog accent and stays the default.
enum AppAccent: String, CaseIterable, Identifiable, Sendable {
    case magenta, orange, blue, mono
    static let key = "app.accent"
    var id: Self { self }

    var title: String {
        switch self {
        case .magenta: String(localized: "accent.magenta", defaultValue: "Magenta")
        case .orange: String(localized: "accent.orange", defaultValue: "Orange")
        case .blue: String(localized: "accent.blue", defaultValue: "Blue")
        case .mono: String(localized: "accent.mono", defaultValue: "Black & White")
        }
    }
    /// One adaptive color for SwiftUI and for UIKit surfaces SwiftUI's tint does not reach.
    var uiColor: UIColor {
        switch self {
        case .magenta: UIColor(named: "AccentColor") ?? .systemPink
        // Darker than system orange, so white labels on a filled control stay legible.
        case .orange:
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.91, green: 0.40, blue: 0.04, alpha: 1)
                    : UIColor(red: 0.83, green: 0.33, blue: 0, alpha: 1)
            }
        case .blue: .systemBlue
        case .mono: .label
        }
    }
    var color: Color { Color(uiColor: uiColor) }
    /// Text and glyphs on a shape filled with the accent.
    var foreground: Color { self == .mono ? Color(uiColor: .systemBackground) : .white }
    /// An unselected control beside an accent-colored selected one. Black & White has no hue
    /// to mark the selection, so the unselected controls step back instead.
    var idle: Color { self == .mono ? .secondary : .primary }
}

extension EnvironmentValues {
    @Entry var appAccent = AppAccent.magenta
}

/// `.foregroundStyle(.onAccent)` for content drawn on an accent fill.
struct OnAccentStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color { environment.appAccent.foreground }
}
extension ShapeStyle where Self == OnAccentStyle {
    static var onAccent: OnAccentStyle { OnAccentStyle() }
}

private struct AppAccentModifier: ViewModifier {
    @AppStorage(AppAccent.key) private var accent = AppAccent.magenta
    func body(content: Content) -> some View {
        content.tint(accent.color).environment(\.appAccent, accent)
            .onChange(of: accent, initial: true) { _, accent in
                // Alerts, menus and system pickers take their tint from the window.
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    for window in scene.windows { window.tintColor = accent.uiColor }
                }
            }
    }
}
extension View {
    /// Apply the chosen accent to the whole interface. Use once, at the root.
    func appAccent() -> some View { modifier(AppAccentModifier()) }
}

/// One row of swatches; the choice applies at once.
struct AccentPicker: View {
    @AppStorage(AppAccent.key) private var accent = AppAccent.magenta
    var body: some View {
        LabeledContent(String(localized: "about.accent", defaultValue: "Accent color")) {
            HStack(spacing: 0) {
                ForEach(AppAccent.allCases) { option in
                    Button {
                        accent = option
                    } label: {
                        swatch(option).frame(width: 24, height: 24)
                            .padding(4)
                            .overlay {
                                if accent == option { Circle().strokeBorder(Color.primary, lineWidth: 2) }
                            }
                            .frame(width: 44, height: 44).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(accent == option ? .isSelected : [])
                    .accessibilityIdentifier("about.accent." + option.rawValue)
                }
            }
        }
    }
    @ViewBuilder private func swatch(_ option: AppAccent) -> some View {
        if option == .mono {
            Circle().fill(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.5), .init(color: .white, location: 0.5),
                    ], startPoint: .leading, endPoint: .trailing)
            ).overlay { Circle().strokeBorder(Color(uiColor: .separator)) }
        } else {
            Circle().fill(option.color)
        }
    }
}
