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
    private struct BatchRequest: Identifiable {
        let id = UUID()
        let items: [BatchExportItem]
    }
    private enum ImportSource { case photos, files }
    private var visible: [LibraryPhoto] { library.photos.filter { filter.includes($0) } }
    private var sections: [(day: Date, photos: [LibraryPhoto])] {
        Dictionary(grouping: visible, by: { Calendar.current.startOfDay(for: $0.date) })
            .map { (day: $0.key, photos: $0.value) }.sorted { $0.day > $1.day }
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
                    CameraButton(prominent: true)
                        .padding(.trailing, 26).padding(.bottom, 12)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Text(
                        selecting
                            ? String(
                                localized: "library.selected",
                                defaultValue: "\(selection.count) selected")
                            : String(
                                localized: "library.photo_count",
                                defaultValue: "\(visible.count) photos")
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.vertical, 6).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("library.count")
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
                            if selecting {
                                Image(systemName: "xmark")
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
                                    localized: "library.revert_selected_photos",
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
                                            "library.this_removes_all_edits_from_the_selected",
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
                    ToolbarItem(placement: .bottomBar) { Spacer() }
                    ToolbarItem(placement: .bottomBar) {
                        Button(
                            String(localized: "library.lut_manager", defaultValue: "LUT Manager")
                        ) { showLUTs = true }
                        .accessibilityIdentifier("library.luts").disabled(working)
                    }
                    ToolbarItem(placement: .bottomBar) { Spacer() }
                    ToolbarItem(placement: .bottomBar) {
                        Button(
                            String(localized: "common.delete", defaultValue: "Delete"),
                            systemImage: "trash", role: .destructive
                        ) { confirmDelete = true }
                        .accessibilityIdentifier("library.delete")
                        .disabled(!selecting || selection.isEmpty || working)
                        .confirmationDialog(
                            String(
                                localized: "library.delete_photos",
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
                                    localized: "library.this_removes_the_app_copies_and_their",
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

                .alert(
                    String(localized: "library.library", defaultValue: "Library"),
                    isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
                ) {
                    Button(String(localized: "common.ok", defaultValue: "OK"), role: .cancel) {}
                } message: {
                    Text(failure ?? "")
                }
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
                            localized: "library.import_photos_from_photos_or_files",
                            defaultValue: "Import photos from Photos or Files.")))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Color.clear.frame(height: 0).id("library.latest")
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3),
                            spacing: 2
                        ) {
                            ForEach(sections, id: \.day) { section in
                                Section {
                                    ForEach(section.photos.sorted { $0.date > $1.date }) { photo in
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
                                                    localized: "library.edited",
                                                    defaultValue: "Edited")
                                                : String(
                                                    localized: "library.original",
                                                    defaultValue: "Original")
                                        )
                                        .accessibilityAddTraits(
                                            selection.contains(photo.id) ? .isSelected : []
                                        )
                                        .accessibilityIdentifier("library.photo.\(photo.id)")
                                        .id(photo.id)
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
                localized: "library.couldn_t_import_errors_photos_check_the",
                defaultValue: "Couldn’t import \(errors) photos. Check the files and try again.")
        }
    }
}
