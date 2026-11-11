import SwiftUI

/// Editing modes; Export is a separate command. ED-02.
enum EditorTool: String, CaseIterable, Identifiable {
    case crop
    case develop
    case adjust
    case effects

    var id: Self { self }

    var title: String {
        switch self {
        case .crop: String(localized: "editor.crop", defaultValue: "Crop")
        case .develop: String(localized: "editor.develop", defaultValue: "Develop")
        case .adjust: String(localized: "editor.adjust", defaultValue: "Adjust")
        case .effects: String(localized: "editor.effects", defaultValue: "Effects")
        }
    }

    var symbolName: String {
        switch self {
        case .crop: "crop"
        case .develop: "camera.filters"
        case .adjust: "slider.horizontal.3"
        case .effects: "sparkles"
        }
    }
}

/// Photo tools stay in one group; the trailing action opens Darkroom or exports its print.
struct EditorToolbar: ToolbarContent {
    @Binding var activeTool: EditorTool?
    var darkroomActive = false
    let openDarkroom: () -> Void
    let export: () -> Void
    private var actionTitle: String {
        darkroomActive
            ? String(localized: "common.export", defaultValue: "Export")
            : String(localized: "darkroom.title", defaultValue: "Darkroom")
    }
    private var actionSymbol: String { darkroomActive ? "square.and.arrow.up" : "lightbulb" }
    var body: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            ControlGroup {
                ForEach(EditorTool.allCases) { tool in
                    Button {
                        activeTool = activeTool == tool ? nil : tool
                    } label: {
                        toolLabel(tool.title, symbol: tool.symbolName, selected: activeTool == tool)
                    }
                    .accessibilityAddTraits(activeTool == tool ? .isSelected : [])
                    .accessibilityIdentifier("editor.tool." + tool.rawValue)
                    .accessibilityShowsLargeContentViewer {
                        Label(tool.title, systemImage: tool.symbolName)
                    }
                }
            }.controlGroupStyle(.navigation).controlSize(.small)
        }
        ToolbarSpacer(.fixed, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button(action: darkroomActive ? export : openDarkroom) {
                toolLabel(actionTitle, symbol: actionSymbol, selected: false)
            }
            .accessibilityLabel(actionTitle)
            .accessibilityIdentifier(darkroomActive ? "darkroom.export" : "editor.export")
            .accessibilityShowsLargeContentViewer {
                Label(actionTitle, systemImage: actionSymbol)
            }
        }
    }
    private func toolLabel(_ title: String, symbol: String, selected: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(
                width: 24, height: 22)
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                .minimumScaleFactor(0.8).frame(height: 12)
        }
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .frame(width: 44, height: 44).contentShape(.rect)
    }
}
