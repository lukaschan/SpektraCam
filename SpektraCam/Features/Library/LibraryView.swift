import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let library: PhotoLibrary
    @Binding var path: [UUID]
    var scrollToLatestRequest = 0
    @State private var filter = LibraryFilter.all
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var importSource: ImportSource?
    @State private var working = false
    @State private var progress = ""
    @State private var failure: String?
    @State private var confirmDelete = false
    @State private var confirmRevert = false
    @State private var showLUTs = false
    @State private var showInformation = false
    @State private var importFilesAfterInfo = false
    @State private var handledCameraRequest = 0
    @State private var scrollRevision = 0
    @State private var batchRequest: BatchRequest?
    @State private var pasteTargets: Set<UUID> = []
    @State private var showPasteLook = false
    @State private var systemVerticalBar = false
    @Environment(\.openCamera) private var openCamera
    private struct BatchRequest: Identifiable {
        let id = UUID()
        let items: [BatchExportItem]
    }
    private enum ImportSource { case photos, files }
    private var visible: [LibraryPhoto] { library.photos.filter { filter.includes($0) } }
    /// Newest day first, newest photo first. The library keeps its photos in date order, so
    /// one pass from the end groups them without hashing or sorting.
    private var sections: [(day: Date, photos: [LibraryPhoto])] {
        let calendar = Calendar.current
        var result: [(day: Date, photos: [LibraryPhoto])] = []
        for photo in visible.reversed() {
            let day = calendar.startOfDay(for: photo.date)
            if result.last?.day == day {
                result[result.count - 1].photos.append(photo)
            } else {
                result.append((day, [photo]))
            }
        }
        return result
    }
    private func presented(_ source: ImportSource) -> Binding<Bool> {
        Binding(
            get: { importSource == source },
            set: {
                if $0 {
                    importSource = source
                } else if importSource == source {
                    importSource = nil
                }
            })
    }
    var body: some View {
        NavigationStack(path: $path) {
            gallery
                .overlay(alignment: .bottomTrailing) {
                    // Where the system keeps a bar on the side, the camera joins it.
                    if !systemVerticalBar {
                        CameraButton(prominent: true)
                            .padding(.trailing, 26).padding(.bottom, 12)
                    }
                }
                .onSystemVerticalBar { systemVerticalBar = $0 }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 2) {
                        if let undo = library.pasteUndo {
                            HStack(spacing: 10) {
                                Text(
                                    String(
                                        localized: "look.pasted_count",
                                        defaultValue: "Look pasted to \(undo.count) photos"))
                                Button(String(localized: "editor.undo", defaultValue: "Undo")) {
                                    working = true
                                    Task {
                                        do { try await library.undoPaste() } catch {
                                            failure = error.localizedDescription
                                        }
                                        working = false
                                    }
                                }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                                .disabled(working).accessibilityIdentifier("library.look.undo")
                            }
                            .padding(.top, 6)
                        }
                        Text(
                            selecting
                                ? String(
                                    localized: "library.selected",
                                    defaultValue: "\(selection.count) selected")
                                : String(
                                    localized: "library.photo_count",
                                    defaultValue: "\(visible.count) photos")
                        )
                        .foregroundStyle(.secondary).padding(.vertical, 6)
                        .accessibilityIdentifier("library.count")
                    }
                    .font(.footnote).frame(maxWidth: .infinity)
                }
                .sheet(isPresented: $showInformation, onDismiss: {
                    if importFilesAfterInfo {
                        importFilesAfterInfo = false
                        importSource = .files
                    }
                }) {
                    AppInformationView(importFiles: { importFilesAfterInfo = true })
                }
                .sheet(isPresented: $showLUTs) { LUTLibraryView(library: library) }
                .sheet(item: $batchRequest) { request in
                    BatchExportPanel(items: request.items, library: library)
                }
                .sheet(isPresented: $showPasteLook) {
                    if let clip = library.copiedLook {
                        PasteLookSheet(
                            library: library, clip: clip, count: pasteTargets.count, paste: pasteLook)
                    }
                }
                .navigationTitle(String(localized: "library.library", defaultValue: "Library"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(
                            String(
                                localized: "library.about_and_settings",
                                defaultValue: "About and Settings"), systemImage: "info"
                        ) { showInformation = true }
                        .labelStyle(.iconOnly).buttonBorderShape(.circle)
                        .accessibilityIdentifier("library.info")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker(
                                String(localized: "library.show", defaultValue: "Show"),
                                selection: $filter
                            ) {
                                ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
                            }
                        } label: {
                            Label(
                                String(localized: "library.filter", defaultValue: "Filter"),
                                systemImage: filter == .all
                                    ? "line.3.horizontal.decrease"
                                    : "line.3.horizontal.decrease.circle.fill")
                        }
                        .accessibilityIdentifier("library.filter").disabled(working)
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            selecting.toggle()
                            selection.removeAll()
                        } label: {
                            // A side bar shows symbols; a top bar has room for the word.
                            if selecting {
                                Image(systemName: "xmark")
                            } else if systemVerticalBar {
                                Label(
                                    String(localized: "common.select", defaultValue: "Select"),
                                    systemImage: "checkmark.circle")
                            } else {
                                Text(String(localized: "common.select", defaultValue: "Select"))
                            }
                        }
                        .buttonBorderShape(selecting ? .circle : .capsule)
                        .accessibilityLabel(
                            selecting
                                ? String(
                                    localized: "library.cancel_selection",
                                    defaultValue: "Cancel Selection")
                                : String(localized: "common.select", defaultValue: "Select")
                        )
                        .accessibilityIdentifier("library.select").disabled(
                            working || visible.isEmpty)
                    }
                    ToolbarItem(placement: .bottomBar) {
                        if selecting {
                            Button(
                                String(localized: "common.export", defaultValue: "Export"),
                                systemImage: "square.and.arrow.up"
                            ) {
                                do {
                                    try library.flushPending()
                                    let items = try library.photos.filter {
                                        selection.contains($0.id)
                                    }.map {
                                        BatchExportItem(
                                            id: $0.id, name: $0.filename,
                                            source: library.files.sourceURL($0),
                                            recipe: try library.recipe($0.id),
                                            width: $0.metadata.width, height: $0.metadata.height)
                                    }
                                    if !items.isEmpty { batchRequest = BatchRequest(items: items) }
                                } catch { failure = error.localizedDescription }
                            }.disabled(working || selection.isEmpty).accessibilityIdentifier(
                                "library.export")
                        }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        if selecting {
                            Menu {
                                Button(
                                    String(localized: "look.copy", defaultValue: "Copy Look"),
                                    systemImage: "slider.horizontal.2.square.on.square"
                                ) { if let id = selection.first { copyLook(id) } }
                                .disabled(
                                    selection.count != 1
                                        || selection.first.flatMap(library.photo)?.hasEdits != true
                                )
                                .accessibilityIdentifier("library.look.copy")
                                Button(
                                    String(localized: "look.paste", defaultValue: "Paste Look…"),
                                    systemImage: "slider.horizontal.2.square.badge.arrow.down"
                                ) {
                                    pasteTargets = selection
                                    showPasteLook = true
                                }
                                .disabled(library.copiedLook == nil || selection.isEmpty)
                                .accessibilityIdentifier("library.look.paste")
                            } label: {
                                Label(
                                    String(localized: "part.look", defaultValue: "Look"),
                                    systemImage: "slider.horizontal.2.square.on.square")
                            }
                            .disabled(working || selection.isEmpty).accessibilityIdentifier("library.look")
                        }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        if selecting {
                            Button(
                                String(localized: "common.revert", defaultValue: "Revert"),
                                systemImage: "arrow.uturn.backward"
                            ) { confirmRevert = true }
                            .accessibilityIdentifier("library.revert")
                            .disabled(
                                working
                                    || !library.photos.contains {
                                        selection.contains($0.id) && $0.hasEdits
                                    }
                            )
                            .confirmationDialog(
                                String(
                                    localized: "library.revert_confirm",
                                    defaultValue: "Revert selected photos?"),
                                isPresented: $confirmRevert,
                                titleVisibility: .visible
                            ) {
                                Button(
                                    String(
                                        localized: "library.revert_to_original",
                                        defaultValue: "Revert to Original"), role: .destructive
                                ) {
                                    let ids = selection
                                    working = true
                                    Task {
                                        do { try await library.revert(ids) } catch {
                                            failure = error.localizedDescription
                                        }
                                        working = false
                                    }
                                }
                            } message: {
                                Text(
                                    String(
                                        localized:
                                            "library.revert_message",
                                        defaultValue:
                                            "This removes all edits from the selected app copies."))
                            }
                        } else {
                            Button {
                                importSource = .photos
                            } label: {
                                Label(
                                    String(localized: "common.import", defaultValue: "Import"),
                                    systemImage: "plus")
                            }
                            .accessibilityIdentifier("library.import").disabled(working)
                            .accessibilityHint(String(localized: "library.from_photos", defaultValue: "From Photos"))
                        }
                    }
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            showLUTs = true
                        } label: {
                            if systemVerticalBar {
                                Label(
                                    String(localized: "lut.manager", defaultValue: "LUT Manager"),
                                    systemImage: "cube")
                            } else {
                                Text(String(localized: "lut.manager", defaultValue: "LUT Manager"))
                            }
                        }
                        .accessibilityIdentifier("library.luts").disabled(working)
                    }
                    if systemVerticalBar {
                        ToolbarItem(placement: .bottomBar) {
                            Button(
                                String(localized: "camera.camera", defaultValue: "Camera"),
                                systemImage: "camera"
                            ) { openCamera?() }
                            .tint(Color.accentColor).accessibilityIdentifier("camera.open")
                        }
                    }
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button(
                            String(localized: "common.delete", defaultValue: "Delete"),
                            systemImage: "trash", role: .destructive
                        ) { confirmDelete = true }
                        .accessibilityIdentifier("library.delete")
                        .disabled(!selecting || selection.isEmpty || working)
                        .confirmationDialog(
                            String(
                                localized: "library.delete_confirm",
                                defaultValue: "Delete \(selection.count) photos?"),
                            isPresented: $confirmDelete,
                            titleVisibility: .visible
                        ) {
                            Button(
                                String(
                                    localized: "library.delete_app_copies",
                                    defaultValue: "Delete App Copies"), role: .destructive
                            ) {
                                let ids = selection
                                working = true
                                Task {
                                    do {
                                        try await library.delete(ids)
                                        selection.removeAll()
                                        selecting = false
                                    } catch { failure = error.localizedDescription }
                                    working = false
                                }
                            }
                        } message: {
                            Text(
                                String(
                                    localized: "library.delete_message",
                                    defaultValue:
                                        "This removes the app copies and their edits. Your source photos stay unchanged."
                                )
                            )
                        }
                    }
                }
                .navigationDestination(for: UUID.self) { id in
                    PhotoDetailView(library: library, id: id, filter: filter)
                }
                .sheet(isPresented: presented(.photos)) {
                    PhotoImportPicker(importedIdentifiers: library.importedAssetIdentifiers) { photos in
                        Task { await importPhotos(photos) }
                    }
                }
                .fileImporter(
                    isPresented: presented(.files), allowedContentTypes: [.image],
                    allowsMultipleSelection: true
                ) { result in
                    switch result {
                    case .success(let urls): Task { await importFiles(urls) }
                    case .failure(let error): failure = error.localizedDescription
                    }
                }
                .onChange(of: scrollToLatestRequest) { _, _ in
                    filter = .all
                    selecting = false
                    selection.removeAll()
                    scrollRevision += 1
                }
                .onChange(of: filter) { _, _ in
                    selection.removeAll()
                    scrollRevision += 1
                }

                .failureAlert(String(localized: "library.library", defaultValue: "Library"), message: $failure)
        }
    }
    private var gallery: some View {
        ZStack {
            if visible.isEmpty {
                ContentUnavailableView(
                    filter == .all
                        ? String(localized: "library.your_library", defaultValue: "Your Library")
                        : String(
                            localized: "library.no_photos",
                            defaultValue: "No \(filter.title) Photos"),
                    systemImage: "photo.on.rectangle",
                    description: Text(
                        String(
                            localized: "library.empty_hint",
                            defaultValue: "Import photos from Photos or Files.")))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Color.clear.frame(height: 0).id("library.latest")
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 118), spacing: 2)],
                            spacing: 2
                        ) {
                            ForEach(sections, id: \.day) { section in
                                Section {
                                    ForEach(section.photos) { photo in
                                        Button {
                                            if selecting {
                                                if selection.contains(photo.id) {
                                                    selection.remove(photo.id)
                                                } else {
                                                    selection.insert(photo.id)
                                                }
                                            } else {
                                                path.append(photo.id)
                                            }
                                        } label: {
                                            LibraryThumbnail(
                                                photo: photo, images: library.images,
                                                selecting: selecting,
                                                selected: selection.contains(photo.id))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(
                                            String(
                                                localized: "library.photo_accessibility_summary",
                                                defaultValue:
                                                    "\(photo.filename), \(photo.isRAW ? "RAW" : photo.metadata.formatLabel), \(photo.date.formatted(date: .abbreviated, time: .shortened))"
                                            )
                                        )
                                        .accessibilityValue(
                                            photo.hasEdits
                                                ? String(
                                                    localized: "photo.edited",
                                                    defaultValue: "Edited")
                                                : String(
                                                    localized: "photo.original",
                                                    defaultValue: "Original")
                                        )
                                        .accessibilityAddTraits(
                                            selection.contains(photo.id) ? .isSelected : []
                                        )
                                        .accessibilityIdentifier("library.photo.\(photo.id)")
                                        .id(photo.id)
                                        .contextMenu {
                                            Button(
                                                String(localized: "common.select", defaultValue: "Select"),
                                                systemImage: "checkmark.circle"
                                            ) {
                                                selecting = true
                                                selection = [photo.id]
                                            }
                                            if photo.hasEdits {
                                                Button(
                                                    String(localized: "look.copy", defaultValue: "Copy Look"),
                                                    systemImage: "slider.horizontal.2.square.on.square"
                                                ) { copyLook(photo.id) }
                                            }
                                            if library.copiedLook != nil {
                                                Button(
                                                    String(
                                                        localized: "look.paste", defaultValue: "Paste Look…"),
                                                    systemImage: "slider.horizontal.2.square.badge.arrow.down"
                                                ) {
                                                    pasteTargets = [photo.id]
                                                    showPasteLook = true
                                                }
                                            }
                                            Button(
                                                String(localized: "common.delete", defaultValue: "Delete"),
                                                systemImage: "trash", role: .destructive
                                            ) {
                                                selecting = true
                                                selection = [photo.id]
                                                confirmDelete = true
                                            }
                                        }
                                    }
                                } header: {
                                    Text(dayTitle(section.day)).font(.headline).frame(
                                        maxWidth: .infinity, alignment: .leading
                                    )
                                    .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 10)
                                }
                            }
                        }
                    }
                    .defaultScrollAnchor(.top, for: .initialOffset)
                    .onChange(of: scrollRevision) { _, _ in
                        proxy.scrollTo("library.latest", anchor: .top)
                        handledCameraRequest = scrollToLatestRequest
                    }
                    .onAppear {
                        if handledCameraRequest != scrollToLatestRequest {
                            proxy.scrollTo("library.latest", anchor: .top)
                            handledCameraRequest = scrollToLatestRequest
                        }
                    }
                    .accessibilityIdentifier("library.grid")
                }
            }
            if working && !progress.isEmpty {
                ImportProgress(text: progress)
            }
        }
        .background(PhotoTheme.canvas)
    }
    private func copyLook(_ id: UUID) {
        do { try library.copyLook(from: id) } catch { failure = error.localizedDescription }
    }
    private func pasteLook(_ parts: Set<EditRecipe.Part>) {
        let ids = pasteTargets
        guard !working else { return }
        working = true
        Task {
            do {
                if try await library.pasteLook(parts, to: ids).skipped > 0 {
                    failure = String(
                        localized: "look.paste.skipped",
                        defaultValue: "Photos edited with an older film model were skipped.")
                }
            } catch { failure = error.localizedDescription }
            working = false
        }
    }
    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return String(localized: "library.today", defaultValue: "Today")
        }
        if Calendar.current.isDateInYesterday(date) {
            return String(localized: "library.yesterday", defaultValue: "Yesterday")
        }
        return date.formatted(.dateTime.month(.wide).day().year())
    }
    private func importPhotos(_ incoming: [PHPickerResult]) async {
        let known = Set(library.importedAssetIdentifiers)
        let photos = incoming.filter { $0.assetIdentifier.map { !known.contains($0) } ?? true }
        guard !working, !photos.isEmpty else { return }
        working = true
        selecting = false
        selection.removeAll()
        var errors = 0
        for (index, photo) in photos.enumerated() {
            progress = String(
                localized: "common.import_progress",
                defaultValue: "Importing \(index + 1) of \(photos.count)…")
            do {
                let file = try await PhotoImportPicker.file(for: photo)
                try await library.importPhoto(file.url, assetIdentifier: photo.assetIdentifier)
            } catch { errors += 1 }
        }
        completeImport(errors)
    }
    private func importFiles(_ urls: [URL]) async {
        guard !working else { return }
        working = true
        selecting = false
        selection.removeAll()
        var errors = 0
        for (index, url) in urls.enumerated() {
            progress = String(
                localized: "common.import_progress",
                defaultValue: "Importing \(index + 1) of \(urls.count)…")
            let scoped = url.startAccessingSecurityScopedResource()
            do { try await library.importPhoto(url) } catch { errors += 1 }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        completeImport(errors)
    }
    private func completeImport(_ errors: Int) {
        working = false
        progress = ""
        filter = .all
        scrollRevision += 1
        if errors > 0 {
            failure = String(
                localized: "library.import_failed",
                defaultValue: "Couldn’t import \(errors) photos. Check the files and try again.")
        }
    }
}
