import MapKit
import SwiftUI

/// Browse the album without loading full-resolution data for each thumbnail.
struct PhotoDetailView: View {
    @AppStorage(PreviewQuality.libraryKey) private var previewMaximum = PreviewQuality.defaultMaximum
    @Environment(\.dismiss) private var dismiss
    let library: PhotoLibrary
    let filter: LibraryFilter
    @State private var selectedID: UUID
    @State private var sourceLens: String?
    private var displayMetadata: PhotoMetadata {
        var result = photo?.metadata ?? PhotoMetadata()
        if result.lens == nil { result.lens = sourceLens }
        return result
    }
    @State private var histogram = PhotoHistogram.empty
    @State private var image: UIImage?
    @State private var imageIdentity: String?
    @State private var editor: EditorSession?
    @State private var export: ExportRequest?
    @State private var working = false
    @State private var failure: String?
    @State private var layout = WorkspaceLayout.stacked
    @State private var systemVerticalBar = false
    @State private var confirmRevert = false
    @State private var confirmDelete = false
    @State private var showPasteLook = false
    @State private var formulaDraft: FormulaDraft?
    private struct ExportRequest: Identifiable {
        let id = UUID()
        let session: EditorSession?
        let originalURL: URL
        let sourceFilename: String
    }
    private var photo: LibraryPhoto? { library.photo(selectedID) }
    private var photos: [LibraryPhoto] { library.photos.filter { filter.includes($0) } }

    init(library: PhotoLibrary, id: UUID, filter: LibraryFilter = .all) {
        self.library = library
        self.filter = filter
        _selectedID = State(initialValue: id)
    }
    var body: some View {
        ZStack {
            AlbumPager(photos: photos, images: library.images, selection: $selectedID)
            if working { ProgressView().padding().background(.regularMaterial, in: .capsule) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PhotoTheme.canvas)
        .overlay(alignment: .bottom) {
            PhotoViewerControls(
                photos: photos, images: library.images, selection: $selectedID,
                working: working, develop: { prepareEditor(exporting: false) },
                export: { prepareEditor(exporting: true) }, revert: revertPhoto,
                canRevert: photo?.hasEdits == true, delete: deletePhoto, layout: layout,
                showsActions: !systemVerticalBar
            )
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .onSystemVerticalBar { systemVerticalBar = $0 }
        .onGeometryChange(for: WorkspaceLayout.self) { WorkspaceLayout($0.size) } action: { layout = $0 }
        .overlay(alignment: .top) {
            if let photo {
                let recipe = savedRecipe
                PhotoInfoPanel(
                    title: filmTitle(recipe), subtitle: printTitle(recipe), metadata: displayMetadata,
                    location: photo.locationName, histogram: histogram, identifier: "photo",
                    look: LookActions(
                        canCopy: photo.hasEdits && !working,
                        canPaste: library.copiedLook != nil && !working,
                        canUndo: library.pasteUndo?.contains(photo.id) == true && !working,
                        copy: {
                            do { try library.copyLook(from: photo.id) } catch {
                                failure = error.localizedDescription
                            }
                        },
                        paste: { showPasteLook = true }, undo: undoPaste),
                    formulae: FormulaStrip(
                        library: library, photo: photo, canSave: photo.hasEdits && !working, applying: working,
                        identifier: "photo", apply: applyFormula,
                        save: { if let recipe = savedRecipe { formulaDraft = FormulaDraft(recipe: recipe) } })
                )
                .padding(.horizontal, 12).padding(.top, 4)
            }
        }
        .navigationTitle(String(localized: "photo.photo", defaultValue: "Photo"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.navigationStack)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let photo { PhotoBanner(photo: photo) }
            }
            PhotoWorkspaceCameraToolbar()
            // Where the system keeps a bar on the side, the actions live in it.
            if systemVerticalBar { sideBarActions }
        }
        .confirmationDialog(
            String(localized: "photo.revert_confirm", defaultValue: "Revert to original?"),
            isPresented: $confirmRevert, titleVisibility: .visible
        ) {
            Button(
                String(localized: "library.revert_to_original", defaultValue: "Revert to Original"),
                role: .destructive, action: revertPhoto)
        }
        .confirmationDialog(
            String(localized: "photo.delete_confirm", defaultValue: "Delete Photo?"),
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button(
                String(localized: "photo.delete_app_copy", defaultValue: "Delete App Copy"),
                role: .destructive, action: deletePhoto)
        } message: {
            Text(
                String(
                    localized: "photo.delete_message",
                    defaultValue:
                        "This removes the app copy and its edits. Your source photo stays unchanged."
                ))
        }
        .task(id: "\(selectedID)-\(photo?.renderKey ?? "")-\(previewMaximum)") {
            await loadPreview()
        }
        .task(id: selectedID) {
            sourceLens = nil
            if let photo {
                let lens = await library.files.lensName(photo)
                guard !Task.isCancelled, photo.id == selectedID else { return }
                sourceLens = lens
            }
            await resolveLocation()
        }
        .onChange(of: selectedID) { _, _ in
            image = nil
            histogram = .empty
        }
        .navigationDestination(item: $editor) { session in
            EditorView(
                session: session, locationName: photo?.locationName, photoID: selectedID, library: library
            ) {
                let recipe = session.hasEdits ? session.recipe : nil
                try await library.finishEditing(selectedID, recipe: recipe)
            }
        }
        .sheet(item: $export) { request in
            if let session = request.session {
                ExportPanel(session: session)
            } else {
                ExportPanel(originalURL: request.originalURL, sourceFilename: request.sourceFilename)
            }
        }
        .sheet(isPresented: $showPasteLook) {
            if let clip = library.copiedLook {
                PasteLookSheet(library: library, clip: clip, paste: pasteLook)
            }
        }
        .sheet(item: $formulaDraft) { draft in
            SaveFormulaSheet(library: library, recipe: draft.recipe)
        }
        .failureAlert(String(localized: "photo.photo", defaultValue: "Photo"), message: $failure)
    }
    private func pasteLook(_ parts: Set<EditRecipe.Part>) {
        let id = selectedID
        working = true
        Task {
            defer { working = false }
            do {
                if try await library.pasteLook(parts, to: [id]).skipped > 0 {
                    failure = String(
                        localized: "look.paste.skipped",
                        defaultValue: "Photos edited with an older film model were skipped.")
                }
            } catch { failure = error.localizedDescription }
        }
    }
    private func applyFormula(_ formula: Formula) {
        let id = selectedID
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                if try await library.applyFormula(formula, to: [id]).skipped > 0 {
                    failure = String(
                        localized: "look.paste.skipped",
                        defaultValue: "Photos edited with an older film model were skipped.")
                }
            } catch { failure = error.localizedDescription }
        }
    }
    private func undoPaste() {
        working = true
        Task {
            defer { working = false }
            do { try await library.undoPaste() } catch { failure = error.localizedDescription }
        }
    }
    @ToolbarContentBuilder private var sideBarActions: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button(String(localized: "editor.develop", defaultValue: "Develop"), systemImage: "camera.filters") {
                prepareEditor(exporting: false)
            }
            .tint(Color.accentColor).disabled(working).accessibilityIdentifier("photo.develop")
        }
        ToolbarSpacer(.fixed, placement: .bottomBar)
        ToolbarItemGroup(placement: .bottomBar) {
            Button(String(localized: "common.export", defaultValue: "Export"), systemImage: "square.and.arrow.up") {
                prepareEditor(exporting: true)
            }
            .disabled(working).accessibilityIdentifier("photo.export")
            Button(String(localized: "common.revert", defaultValue: "Revert"), systemImage: "arrow.uturn.backward") {
                confirmRevert = true
            }
            .disabled(working || photo?.hasEdits != true).accessibilityIdentifier("photo.revert")
            Button(String(localized: "common.delete", defaultValue: "Delete"), systemImage: "trash", role: .destructive) {
                confirmDelete = true
            }
            .disabled(working).accessibilityIdentifier("photo.delete")
        }
    }
    private var savedRecipe: EditRecipe? {
        photo?.recipeData.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: $0) }
    }
    // The saved recipe is decoded once per update and shared by both titles.
    private func filmTitle(_ saved: EditRecipe?) -> String {
        guard let recipe = saved, recipe.look.enabled else {
            return String(localized: "photo.original", defaultValue: "Original")
        }
        if recipe.look.mode == .lut { return "3D LUT" }
        return FilmStock.films.first { $0.id == recipe.filmID }?.name
            ?? String(localized: "film_stock.film", defaultValue: "Film")
    }
    private func printTitle(_ saved: EditRecipe?) -> String {
        guard let recipe = saved, recipe.look.enabled else {
            return photo?.isRAW == true
                ? "RAW"
                : photo?.metadata.formatLabel
                    ?? String(localized: "photo.photo", defaultValue: "Photo")
        }
        if recipe.look.mode == .lut {
            let names = [recipe.look.first.id, recipe.look.second.id].compactMap {
                library.luts.name($0)
            }
            return names.isEmpty
                ? String(localized: "lut.none_selected", defaultValue: "No LUT selected")
                : names.joined(separator: " · ")
        }
        return recipe.bypassesPrint
            ? String(localized: "develop.direct_scan", defaultValue: "Direct scan")
            : FilmStock.prints.first { $0.id == recipe.printID }?.name
                ?? String(localized: "develop.print", defaultValue: "Print")
    }
    private func loadPreview() async {
        guard let photo else { return }
        do {
            let frame = try await library.images.image(photo, thumbnail: false)
            try Task.checkCancellation()
            image = UIImage(cgImage: frame)
            imageIdentity = "\(photo.id)-\(photo.renderKey)"
            let stats = await HistogramWorker.shared.make(frame)
            if !Task.isCancelled { histogram = stats }
            // The precise viewer is already visible. Prepare one neutral source after
            // a short pause; fast paging cancels this before another RAW decode starts.
            if photo.hasEdits {
                try await Task.sleep(for: .milliseconds(150))
                _ = try? await library.files.decodedPhoto(photo)
            }
        } catch { if !Task.isCancelled { histogram = .empty } }
    }
    private func revertPhoto() {
        working = true
        Task {
            defer { working = false }
            do { try await library.revert([selectedID]) } catch {
                failure = error.localizedDescription
            }
        }
    }
    private func deletePhoto() {
        guard !working else { return }
        let id = selectedID
        let album = photos.map(\.id)
        let index = album.firstIndex(of: id) ?? 0
        let next = album.dropFirst(index + 1).first ?? album.prefix(index).last
        working = true
        Task {
            defer { working = false }
            do {
                try await library.delete([id])
                if let next { selectedID = next } else { dismiss() }
            } catch { failure = error.localizedDescription }
        }
    }
    private func prepareEditor(exporting: Bool) {
        guard !working, let photo else { return }
        do {
            let recipe = try library.recipe(photo.id)
            if exporting && recipe == nil {
                export = ExportRequest(session: nil, originalURL: library.files.sourceURL(photo), sourceFilename: photo.filename)
                return
            }
            if let recipe, recipe.upstreamRevision != EditRecipe().upstreamRevision {
                throw LibraryFiles.Failure.image
            }
            working = true
            Task {
                defer { working = false }
                do {
                    let neutral = !photo.hasEdits && imageIdentity == "\(photo.id)-\(photo.renderKey)"
                        ? image?.cgImage : nil
                    let imported = try await library.files.decodedPhoto(photo, neutralPreview: neutral)
                    guard selectedID == photo.id else { return }
                    let session = EditorSession(
                        photo: imported, recipe: recipe, luts: library.luts,
                        resources: library.images.resources, sourceFilename: photo.filename)
                    if let image, photo.hasEdits, recipe?.filmEdgeLayout == nil, recipe?.printLayout == nil {
                        session.displayImage = image
                    }
                    if exporting {
                        export = ExportRequest(
                            session: session, originalURL: library.files.sourceURL(photo), sourceFilename: photo.filename)
                    } else {
                        session.recipeDidChange = { recipe, immediate in
                            library.queueRecipe(recipe, for: photo.id, immediate: immediate)
                        }
                        editor = session
                    }
                } catch { failure = error.localizedDescription }
            }
        } catch { failure = error.localizedDescription }
    }
    private func resolveLocation() async {
        guard let photo, photo.locationName == nil,
            let latitude = photo.metadata.latitude, let longitude = photo.metadata.longitude,
            let request = MKReverseGeocodingRequest(
                location: CLLocation(latitude: latitude, longitude: longitude))
        else { return }
        do {
            let items = try await withTaskCancellationHandler {
                try await request.mapItems
            } onCancel: {
                request.cancel()
            }
            try Task.checkCancellation()
            if let item = items.first,
                let name = item.addressRepresentations?.cityWithContext ?? item.name
            {
                try library.setLocationName(name, for: photo.id)
            }
        } catch { /* Keep the capture date when the optional lookup is unavailable. */  }
    }
}

/// Capture details stay visible without opening the information panel.
private struct PhotoBanner: View {
    let photo: LibraryPhoto
    private var title: String {
        photo.locationName ?? photo.date.formatted(date: .long, time: .omitted)
    }
    private var detail: String {
        photo.date.formatted(
            date: photo.locationName == nil ? .omitted : .abbreviated, time: .shortened)
    }
    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold)).accessibilityIdentifier(
                "photo.banner.title")
            HStack(spacing: 5) {
                Text(detail).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier(
                    "photo.banner.date")
                if photo.isRAW { PhotoBadge(text: "RAW", compact: true) }
                if photo.hasEdits { PhotoBadge(symbol: PhotoBadge.editedSymbol, compact: true) }
            }
        }.lineLimit(1).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// Controls float over the image. Native popovers anchor to their source button.
private struct PhotoViewerControls: View {
    let photos: [LibraryPhoto]
    let images: LibraryImages
    @Binding var selection: UUID
    let working: Bool
    let develop: () -> Void
    let export: () -> Void
    let revert: () -> Void
    let canRevert: Bool
    let delete: () -> Void
    var layout = WorkspaceLayout.stacked
    /// False where the system's side bar already carries the actions.
    var showsActions = true
    @State private var confirmRevert = false
    var body: some View {
        if !showsActions {
            PhotoFilmstrip(photos: photos, images: images, selection: $selection).disabled(working)
        } else if layout == .sideBySide {
            sideBySide
        } else {
            stacked
        }
    }
    /// With width to spare, the actions run down the trailing edge and leave the photo its height.
    private var sideBySide: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                Color.clear.frame(width: 104, height: 1)
                PhotoFilmstrip(photos: photos, images: images, selection: $selection)
                    .frame(maxWidth: .infinity)
                VStack(spacing: 10) {
                    exportButton
                    Button(String(localized: "editor.develop", defaultValue: "Develop"),
                           systemImage: "camera.filters", action: develop)
                        .labelStyle(.iconOnly).font(.system(size: 20, weight: .medium))
                        .buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.large)
                        .foregroundStyle(.onAccent).frame(width: 56, height: 56)
                        .accessibilityIdentifier("photo.develop")
                    Button {
                        confirmRevert = true
                    } label: {
                        Label(String(localized: "common.revert", defaultValue: "Revert"), systemImage: "arrow.uturn.backward")
                    }
                    .accessibilityLabel(String(localized: "common.revert", defaultValue: "Revert"))
                    .photoActionStyle()
                    .disabled(!canRevert).accessibilityIdentifier("photo.revert")
                    .confirmationDialog(
                        String(localized: "photo.revert_confirm", defaultValue: "Revert to original?"),
                        isPresented: $confirmRevert, titleVisibility: .visible
                    ) {
                        Button(
                            String(localized: "library.revert_to_original", defaultValue: "Revert to Original"),
                            role: .destructive, action: revert)
                    }
                    deleteButton
                }
                .frame(width: 104, alignment: .trailing)
            }
        }.disabled(working)
    }
    private var stacked: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        HStack {
                            exportButton
                            Spacer(minLength: 0)
                        }.frame(width: 104)
                        developButton
                        trailingButtons.frame(width: 104)
                    }
                    VStack(spacing: 10) {
                        developButton
                        HStack {
                            exportButton
                            Spacer()
                            trailingButtons
                        }
                    }
                }.controlSize(.large)
                PhotoFilmstrip(photos: photos, images: images, selection: $selection)
            }
        }.disabled(working)
    }
    private var trailingButtons: some View {
        HStack(spacing: 8) {
            Button {
                confirmRevert = true
            } label: {
                Label(String(localized: "common.revert", defaultValue: "Revert"), systemImage: "arrow.uturn.backward")
            }
            .accessibilityLabel(String(localized: "common.revert", defaultValue: "Revert"))
            .photoActionStyle()
            .disabled(!canRevert).accessibilityIdentifier("photo.revert")
            .confirmationDialog(
                String(localized: "photo.revert_confirm", defaultValue: "Revert to original?"),
                isPresented: $confirmRevert, titleVisibility: .visible
            ) {
                Button(
                    String(
                        localized: "library.revert_to_original",
                        defaultValue: "Revert to Original"), role: .destructive, action: revert)
            }
            deleteButton
        }
    }
    private var developButton: some View {
        Button(action: develop) {
            Text(String(localized: "editor.develop", defaultValue: "Develop")).font(.headline)
                .lineLimit(1).fixedSize(
                    horizontal: true, vertical: false
                )
                .padding(.horizontal, 24)
        }.buttonStyle(.glassProminent).foregroundStyle(.onAccent).accessibilityIdentifier("photo.develop")
    }
    private var exportButton: some View {
        Button(action: export) {
            Label(String(localized: "common.export", defaultValue: "Export"), systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel(String(localized: "common.export", defaultValue: "Export")).photoActionStyle().accessibilityIdentifier(
            "photo.export")
    }
    private var deleteButton: some View { PhotoDeleteButton(action: delete) }
}

private struct PhotoDeleteButton: View {
    let action: () -> Void
    @State private var confirmDelete = false
    var body: some View {
        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            Label(String(localized: "common.delete", defaultValue: "Delete"), systemImage: "trash")
        }
        .accessibilityLabel(String(localized: "common.delete", defaultValue: "Delete")).photoActionStyle().accessibilityIdentifier(
            "photo.delete"
        )
        .confirmationDialog(
            String(localized: "photo.delete_confirm", defaultValue: "Delete Photo?"),
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button(
                String(localized: "photo.delete_app_copy", defaultValue: "Delete App Copy"),
                role: .destructive, action: action)
        } message: {
            Text(
                String(
                    localized: "photo.delete_message",
                    defaultValue:
                        "This removes the app copy and its edits. Your source photo stays unchanged."
                ))
        }
    }
}

/// Each page loads a cached preview; full originals stay outside the paging view.
struct AlbumPhotoPage: View {
    @AppStorage(PreviewQuality.libraryKey) private var previewMaximum = PreviewQuality.defaultMaximum
    let photo: LibraryPhoto
    let images: LibraryImages
    var onTap: (() -> Void)? = nil
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var retry = 0
    var body: some View {
        Group {
            if let image {
                PhotoViewport(image: image, topInset: PhotoInfoPanel.collapsedHeight + 4,
                    edited: photo.hasEdits, topAligned: false, usePortraitReference: true,
                    onTap: { _ in onTap?() })
            } else if let failure {
                ContentUnavailableView {
                    Label(
                        String(
                            localized: "photo.load_failed",
                            defaultValue: "Couldn’t show photo"),
                        systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button(String(localized: "common.retry", defaultValue: "Retry")) { retry += 1 }
                }
            } else {
                ProgressView(
                    String(localized: "photo.loading", defaultValue: "Loading photo…"))
            }
        }
        .task(id: "\(photo.renderKey)-\(retry)-\(previewMaximum)") {
            do {
                if image == nil, let thumbnail = await images.cachedThumbnail(photo) {
                    try Task.checkCancellation()
                    image = UIImage(cgImage: thumbnail)
                }
                let frame = try await images.image(photo, thumbnail: false)
                try Task.checkCancellation()
                image = UIImage(cgImage: frame)
                failure = nil
            } catch {
                if !Task.isCancelled { image = nil; failure = error.localizedDescription }
            }
        }
    }
}
