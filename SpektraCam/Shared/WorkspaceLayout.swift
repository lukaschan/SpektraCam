import SwiftUI

/// How the editor and Darkroom arrange themselves in the space they are given.
///
/// The decision follows the container's size, never the device or its orientation: iPad,
/// iPhone Duo's two displays, Split View and Stage Manager all hand the app arbitrary sizes.
/// A space taller than it is wide keeps the iPhone layout, with controls over the bottom of
/// the photo. A space wider than it is tall puts the controls in a column beside the photo
/// and the tools in a rail on the trailing edge.
nonisolated enum WorkspaceLayout: Equatable, Sendable {
    case stacked, sideBySide

    init(_ size: CGSize) {
        self = size.width > size.height && size.width >= 560 ? .sideBySide : .stacked
    }

    /// Width of the controls column: wide enough for a slider row, never more than the photo.
    static func panelWidth(in width: CGFloat) -> CGFloat {
        min(420, max(300, width * 0.38))
    }
}

extension View {
    /// Report whether the system is showing its bars vertically along a side, as iPhone Duo
    /// does on its outer display and on its inner display in landscape. Toolbar items made of a
    /// title and a symbol move there on their own; custom views do not.
    @ViewBuilder func onSystemVerticalBar(_ action: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 27.1, *) { modifier(VerticalBarProbe(action: action)) } else { self }
    }
}

@available(iOS 27.1, *)
private struct VerticalBarProbe: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var edge
    let action: (Bool) -> Void
    func body(content: Content) -> some View {
        content.onChange(of: edge != nil, initial: true) { _, vertical in action(vertical) }
    }
}
