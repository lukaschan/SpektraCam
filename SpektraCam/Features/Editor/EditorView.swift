import Combine
import SwiftUI
import UIKit

/// The photograph stays visible while contextual controls edit one shared recipe.
struct EditorView: View {
    let session: EditorSession
    var locationName: String? = nil
    /// The library photo being edited, so a copied look can show where it came from.
    var photoID: UUID? = nil
    let library: PhotoLibrary
    let onFinish: () async throws -> Void
    @State private var closing = false
    @State private var closeFailure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent
    @State private var activeTool: EditorTool? = .develop
    @State private var panelExpanded = false
    @State private var inspectorFrame = CGRect.zero
    @State private var adjustSection = AdjustPanel.Section.exposure
    @State private var effectsSection = EffectsPanel.Section.grain
    @ScaledMetric(relativeTo: .footnote) private var collapsedLiftGainHeight: CGFloat = 176
    @ScaledMetric(relativeTo: .footnote) private var collapsedColorHeight: CGFloat = 208
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showExport = false
    @State private var showDarkroom = false
    @State private var cropReturnsToDarkroom = false
    @State private var toolBeforeDarkroomCrop: EditorTool?
    @State private var showOriginal = false
    @State private var showPasteLook = false
    @State private var showResetConfirmation = false
    @State private var showRenderProgress = false
    @State private var layout = WorkspaceLayout.stacked
    @State private var systemVerticalBar = false

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if showDarkroom {
                    DarkroomWorkspace(
                        session: session, suspended: showExport, layout: layout,
                        adjustCrop: openDarkroomCrop)
                } else {
                    editorWorkspace
                }
            }
            if layout == .sideBySide && !systemVerticalBar {
                EditorToolRail(
                    activeTool: toolSelection, darkroomActive: showDarkroom,
                    openDarkroom: openDarkroom, export: { showExport = true }
                )
                .padding(.horizontal, 8)
            }
        }
        .background(PhotoTheme.canvas)
        .onGeometryChange(for: WorkspaceLayout.self) { WorkspaceLayout($0.size) } action: { layout = $0 }
        .onSystemVerticalBar { systemVerticalBar = $0 }
        .background(EditorNavigationGuard().allowsHitTesting(false))
        .sheet(isPresented: $showPasteLook) {
            if let clip = library.copiedLook {
                PasteLookSheet(library: library, clip: clip) { parts in
                    // One history step: the editor's own Undo takes the paste back.
                    session.update(key: "look.paste") {
                        $0 = $0.taking(
                            parts, from: clip.recipe, rawTarget: session.photo.rawTemperature != nil)
                    }
                }
            }
        }
        .navigationTitle(
            showDarkroom
                ? String(localized: "darkroom.title", defaultValue: "Darkroom")
                : activeTool?.title ?? String(localized: "editor.editor", defaultValue: "Editor")
        )
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // A wide space has its own tool rail, unless the system already keeps a bar on the side.
            if layout == .stacked || systemVerticalBar {
                EditorToolbar(
                    activeTool: toolSelection, darkroomActive: showDarkroom,
                    systemVerticalBar: systemVerticalBar,
                    openDarkroom: openDarkroom, export: { showExport = true })
            }
            ToolbarItem(placement: .topBarLeading) {
                // Darkroom is the last step: back saves the edit and returns to the photo, like Close.
                Button(closeTitle, systemImage: showDarkroom ? "chevron.left" : "xmark", action: finish)
                    .photoActionStyle()
                    .accessibilityLabel(closeTitle)
                .accessibilityIdentifier(showDarkroom ? "darkroom.back" : "editor.back")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarLeading) {
                Menu(
                    String(localized: "editor.history", defaultValue: "History"),
                    systemImage: "arrow.uturn.backward"
                ) {
                    Button(
                        String(localized: "editor.undo", defaultValue: "Undo"),
                        systemImage: "arrow.uturn.backward", action: session.undo
                    ).disabled(
                        !session.canUndo)
                    Button(
                        String(localized: "editor.redo", defaultValue: "Redo"),
                        systemImage: "arrow.uturn.forward", action: session.redo
                    ).disabled(
                        !session.canRedo)
                    Divider()
                    Button(
                        String(
                            localized: "editor.reset_all_edits",
                            defaultValue: "Reset All Edits"), role: .destructive
                    ) { showResetConfirmation = true }
                    .disabled(!session.hasEdits)
                }
                .photoActionStyle()
                .accessibilityLabel(String(localized: "editor.history", defaultValue: "History"))
                .accessibilityIdentifier("editor.history")
            }
            .sharedBackgroundVisibility(.visible)
            PhotoWorkspaceCameraToolbar()
        }
        .task(id: session.isBusy) {
            showRenderProgress = false
            guard session.isBusy else { return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            if !Task.isCancelled { showRenderProgress = true }
        }
        .disabled(closing)
        .overlay {
            if closing {
                ProgressView(
                    String(localized: "editor.saving_edits", defaultValue: "Saving edits…"))
            }
        }
        .failureAlert(
            String(localized: "editor.couldn_t_save_edits", defaultValue: "Couldn’t save edits"),
            message: $closeFailure)
        .task {
            await library.images.beginEditing(owner: session.id)
            guard !Task.isCancelled else {
                await library.images.endEditing(owner: session.id)
                return
            }
            session.resumeRendering()
        }
        .onDisappear {
            session.cancelRendering()
            Task { await library.images.endEditing(owner: session.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            session.cancelRendering()
        }
        .onChange(of: activeTool) { _, _ in
            showOriginal = false
            panelExpanded = false
        }
        .alert(
            String(localized: "editor.reset_all_edits_confirm", defaultValue: "Reset all edits?"),
            isPresented: $showResetConfirmation
        ) {
            Button(
                String(localized: "editor.reset_all_edits", defaultValue: "Reset All Edits"),
                role: .destructive
            ) {
                session.resetAll()
            }
        }
        .sheet(isPresented: $showExport, onDismiss: { session.resumeAfterExport() }) {
            ExportPanel(session: session)
        }
        .alert(
            String(
                localized: "editor.couldn_t_render_preview", defaultValue: "Couldn’t render preview"
            ),
            isPresented: Binding(get: { session.renderFailed }, set: { session.renderFailed = $0 })
        ) {
            Button(
                String(localized: "common.retry", defaultValue: "Retry"),
                action: session.renderGeometry)
            Button(
                String(localized: "editor.reset_rotation", defaultValue: "Reset Rotation"),
                role: .cancel
            ) {
                session.update(key: "geometry.reset") { $0.geometry = ImageGeometry() }
            }
        }
    }
    private var closeTitle: String {
        showDarkroom
            ? String(localized: "darkroom.back_to_photo", defaultValue: "Back to photo")
            : String(localized: "editor.close_editor", defaultValue: "Close Editor")
    }
    private var compareTitle: String {
        showOriginal
            ? String(localized: "editor.show_edited", defaultValue: "Show Edited")
            : String(localized: "editor.show_original", defaultValue: "Show Original")
    }
    /// Choosing a tool leaves Darkroom; choosing Crop from a film edge returns there afterwards.
    private var toolSelection: Binding<EditorTool?> {
        Binding(
            get: { showDarkroom ? nil : activeTool },
            set: { tool in
                cropReturnsToDarkroom = tool == .crop && showDarkroom && session.recipe.filmEdgeLayout != nil
                if cropReturnsToDarkroom { toolBeforeDarkroomCrop = activeTool }
                activeTool = tool
                showDarkroom = false
            })
    }
    private func openDarkroom() {
        setExpanded(false)
        cropReturnsToDarkroom = false
        showDarkroom = true
    }
    @ViewBuilder private var editorWorkspace: some View {
        if layout == .sideBySide { sideBySideWorkspace } else { stackedWorkspace }
    }
    /// The photo keeps the leading side; the open tool's controls fill a column beside it.
    private var sideBySideWorkspace: some View {
        GeometryReader { workspace in
            HStack(spacing: 0) {
                canvas
                if activeTool == .crop {
                    ScrollView { toolPanel.padding(.top, 12) }
                        .scrollBounceBehavior(.basedOnSize)
                        .background(.background, in: .rect(cornerRadius: 24))
                        .clipShape(.rect(cornerRadius: 24))
                        .frame(width: WorkspaceLayout.panelWidth(in: workspace.size.width))
                        .padding(.leading, 8).padding(.vertical, 8)
                } else if activeTool != nil {
                    inspector(height: nil)
                        .frame(width: WorkspaceLayout.panelWidth(in: workspace.size.width))
                        .padding(.leading, 8).padding(.vertical, 8)
                }
            }
        }
    }
    private var stackedWorkspace: some View {
        VStack(spacing: 0) {
            GeometryReader { workspace in
                canvas.overlay(alignment: .bottom) {
                    if activeTool != nil && activeTool != .crop {
                        let maximum = maximumPanelHeight(in: workspace.size.height)
                        inspector(height: panelExpanded ? maximum : min(maximum, collapsedPanelHeight))
                            .padding(.horizontal, 12).padding(.bottom, 8)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                inspectorFrame = $0
                            }
                    }
                }
            }
            if activeTool == .crop { toolPanel }
        }
    }
    private func finish() {
        guard !closing else { return }
        closing = true
        Task {
            do {
                try await onFinish()
                dismiss()
            } catch { closeFailure = error.localizedDescription }
            closing = false
        }
    }
    private func openDarkroomCrop() {
        setExpanded(false)
        toolBeforeDarkroomCrop = activeTool
        cropReturnsToDarkroom = true
        activeTool = .crop
        showDarkroom = false
    }
    private func finishDarkroomCrop() {
        activeTool = toolBeforeDarkroomCrop
        cropReturnsToDarkroom = false
        showDarkroom = true
    }
    private var canvas: some View {
        ZStack {
            if activeTool == .crop {
                CropCanvas(
                    image: session.geometryImage, selection: session.binding(\.crop, key: "crop"),
                    geometry: session.binding(\.geometry, key: "crop.framing")
                )
                .allowsHitTesting(!session.isRendering)
            } else {
                PhotoViewport(
                    image: showOriginal
                        ? UIImage(cgImage: session.photo.preview) : session.displayImage,
                    // Beside its controls the photo has the full height, so it sits in the middle.
                    topAligned: layout == .stacked,
                    onTap: { point in
                        if panelExpanded && point.y < inspectorFrame.minY - 44 {
                            setExpanded(false)
                        }
                    },
                    detail: showOriginal ? nil : session.detailProvider
                )
                .overlay(alignment: .top) {
                    VStack(spacing: 8) {
                        EditorInfoBar(
                            session: session, showingOriginal: showOriginal, location: locationName,
                            onInteraction: { if panelExpanded { setExpanded(false) } },
                            look: LookActions(
                                canCopy: session.hasEdits, canPaste: library.copiedLook != nil,
                                copy: { library.copyLook(session.recipe, from: photoID) },
                                paste: { showPasteLook = true }))
                        HStack {
                            Spacer()
                            Button(compareTitle, systemImage: "square.on.square") {
                                showOriginal.toggle()
                                if panelExpanded { setExpanded(false) }
                            }
                            .tint(showOriginal ? Color.accentColor : accent.idle)
                            .accessibilityAddTraits(showOriginal ? .isSelected : [])
                            .photoActionStyle()
                            .accessibilityLabel(compareTitle)
                            .accessibilityIdentifier("editor.compare")
                        }
                    }.padding(.horizontal, 12).padding(.top, 4)
                }
            }
            if showRenderProgress {
                ProgressView().accessibilityLabel(
                    String(localized: "editor.rendering_preview", defaultValue: "Rendering preview")
                )
            }
            if session.filmRenderFailed {
                VStack {
                    Spacer()
                    HStack {
                        Label(
                            String(
                                localized: "editor.couldn_t_update_preview",
                                defaultValue: "Couldn’t update preview"),
                            systemImage: "exclamationmark.triangle")
                        Button(
                            String(localized: "common.retry", defaultValue: "Retry"),
                            action: session.renderFilm)
                    }
                    .font(.footnote).padding(12)
                    .background(.regularMaterial, in: .capsule)
                }.padding()
            }
        }
        .background(PhotoTheme.canvas)
    }

    @ViewBuilder private var toolPanel: some View {
        switch activeTool {
        case .crop:
            CropControls(
                crop: session.binding(\.crop, key: "crop"),
                geometry: session.binding(\.geometry, key: "straighten"),
                imageAspect: imageAspect,
                filmGate: session.recipe.filmEdgeLayout,
                rotateLeft: {
                    let aspect = imageAspect
                    session.update(key: "rotate") {
                        $0.crop.rotateLeft(imageAspect: aspect)
                        $0.geometry.rotateLeft()
                    }
                },
                flipHorizontal: {
                    session.update(key: "flip") {
                        $0.crop.flipHorizontal()
                        $0.geometry.flipHorizontal()
                    }
                },
                flipVertical: {
                    session.update(key: "flip") {
                        $0.crop.flipVertical()
                        $0.geometry.flipVertical()
                    }
                },
                reset: {
                    session.update(key: "crop.reset") {
                        $0.crop = CropSelection()
                        $0.geometry = ImageGeometry()
                    }
                },
                done: {
                    if cropReturnsToDarkroom { finishDarkroomCrop() }
                    else { activeTool = nil }
                },
                canReset: session.recipe.crop != CropSelection() || !session.recipe.geometry.isIdentity,
                onStraightenEditingChanged: {
                    session.setInteraction(key: "straighten", active: $0)
                })
        case .develop:
            if session.recipe.look.mode == .spektrafilm {
                DevelopPanel(session: session).padding(.horizontal).padding(.vertical, 12)
                    .disabled(!session.recipe.look.enabled)
            } else {
                LUTPanel(session: session, library: library)
            }
        case .adjust:
            scrollingPanel(id: adjustSection.rawValue) {
                AdjustPanel(session: session, section: adjustSection)
            }
        case .effects:
            scrollingPanel(id: effectsSection.rawValue) {
                EffectsPanel(session: session, section: effectsSection)
                    .disabled(!session.recipe.look.enabled)
            }
        case nil: EmptyView()
        }
    }
    /// A new section starts scrolled to the top: its identity changes with the section.
    private func scrollingPanel(id: String, @ViewBuilder content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .id(id).accessibilityIdentifier("editor.controls")
    }

    private func maximumPanelHeight(in height: CGFloat) -> CGFloat {
        max(120, height - PhotoInfoPanel.collapsedHeight - 12 - 56 - 52 - 8)
    }

    // Collapsed content heights, in points. The category buttons sit above this area.
    private var collapsedPanelHeight: CGFloat {
        switch (activeTool, adjustSection) {
        case (.develop, _): 250
        case (.adjust, .liftGain): collapsedLiftGainHeight
        case (.adjust, .color): collapsedColorHeight
        default: 180
        }
    }

    private func setExpanded(_ expanded: Bool) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { panelExpanded = expanded }
    }
    /// `height` is nil when the panel fills its column and has nothing to expand into.
    private func inspector(height: CGFloat?) -> some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    switch activeTool {
                    case .develop:
                        PanelTabs(
                            options: EditRecipe.LookMode.allCases.map { ($0, $0.title) },
                            selection: Binding(
                                get: { session.recipe.look.mode },
                                set: { mode in
                                    session.update(key: "look.mode") {
                                        $0.look.mode = mode
                                        $0.look.enabled = true
                                    }
                                }),
                            prefix: "develop.mode.", isSelectionActive: session.recipe.look.enabled)
                    case .adjust:
                        PanelTabs(
                            options: AdjustPanel.Section.allCases.map { ($0, $0.title) },
                            selection: $adjustSection, prefix: "adjust.section.")
                    case .effects:
                        PanelTabs(
                            options: EffectsPanel.Section.allCases.map { ($0, $0.title) },
                            selection: $effectsSection, prefix: "effects.section.")
                    case .crop, nil: Spacer()
                    }
                    if height != nil {
                        PanelExpansionButton(expanded: $panelExpanded, identifier: "editor.expand")
                    }
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                // In a column the pills scroll inside the panel's width instead of running past it.
                .clipShape(height == nil ? AnyShape(.rect) : AnyShape(.rect.inset(by: -40)))
                toolPanel.font(.footnote)
                    .frame(height: height).frame(maxHeight: height == nil ? .infinity : nil, alignment: .top)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
            }
        }
    }

    private var imageAspect: CGFloat {
        let source = session.photo.preview
        let aspect = CGFloat(source.width) / CGFloat(source.height)
        return session.recipe.geometry.quarterTurns % 2 == 0 ? aspect : 1 / aspect
    }

}

/// Scope UIKit's two public pop recognizers to this editor; restore on exit.
private struct EditorNavigationGuard: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.lock() }

    final class Controller: UIViewController {
        private var saved: [(UIGestureRecognizer, Bool)] = []

        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            lock()
        }

        override func viewWillDisappear(_ animated: Bool) {
            saved.forEach { $0.0.isEnabled = $0.1 }
            saved.removeAll()
            super.viewWillDisappear(animated)
        }

        func lock() {
            guard let navigationController else { return }
            let recognizers = [
                navigationController.interactivePopGestureRecognizer,
                navigationController.interactiveContentPopGestureRecognizer,
            ].compactMap { $0 }
            for recognizer in recognizers {
                if !saved.contains(where: { $0.0 === recognizer }) {
                    saved.append((recognizer, recognizer.isEnabled))
                }
                if recognizer.isEnabled { recognizer.isEnabled = false }
            }
        }
    }
}
