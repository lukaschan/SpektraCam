import SwiftUI
import UniformTypeIdentifiers

/// Capture at the tap, rather than reading a changing editor/photo from a sheet builder.
struct FormulaDraft: Identifiable {
    let id = UUID()
    let recipe: EditRecipe
}

extension Formula {
    /// Why a formula cannot be applied here, or nil when it can.
    @MainActor func problem(luts: LUTLibrary) -> String? {
        if parts.isEmpty {
            return String(
                localized: "formula.error.newer",
                defaultValue: "This formula needs a newer version of SpektraCam.")
        }
        guard let missing = missingLUTs(installed: Set(luts.items.map(\.id))).first else { return nil }
        return missing.name.isEmpty
            ? String(localized: "formula.lut_missing_unnamed", defaultValue: "Needs a LUT that is not installed")
            : String(localized: "formula.lut_missing", defaultValue: "Needs LUT: \(missing.name)")
    }
    /// "F·C200 → F·CA II", or the parts alone when there is no Look.
    @MainActor func summary(luts: LUTLibrary) -> String {
        guard parts.contains(.look) else { return parts.map(\.title).joined(separator: " · ") }
        if recipe.look.enabled, recipe.look.mode == .lut {
            // A LUT that is not installed is still named, from the formula's own record of it.
            let names = [recipe.look.first.id, recipe.look.second.id].compactMap { $0 }.map { id in
                luts.name(id) ?? self.luts.first { $0.id == id }?.name ?? ""
            }.filter { !$0.isEmpty }
            return (["3D LUT"] + names).joined(separator: " · ")
        }
        let names = recipe.lookNames(luts: luts)
        return [names.film, names.print].compactMap { $0 }.joined(separator: " → ")
    }
}

/// Saved formulae in the information panel: tap one to apply it, or save the current look.
struct FormulaStrip: View {
    let library: PhotoLibrary
    /// The photo to preview each formula on. Nil shows names only: while the editor is open
    /// it owns the renderer, and library images wait.
    var photo: LibraryPhoto? = nil
    var canSave = true
    var applying = false
    let identifier: String
    let apply: (Formula) -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "formula.formulae", defaultValue: "Formulae"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if applying { ProgressView().controlSize(.small) }
                Button(String(localized: "formula.save_as", defaultValue: "Save as Formula…"), action: save)
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                    .disabled(!canSave).accessibilityIdentifier(identifier + ".formula.save")
            }
            if library.formulae.items.isEmpty {
                Text(
                    String(
                        localized: "formula.strip_hint",
                        defaultValue: "Save this look to use it again on other photos.")
                )
                .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(library.formulae.ordered) { formula in
                            let problem = formula.problem(luts: library.luts)
                            Group {
                                if let photo {
                                    Button { apply(formula) } label: {
                                        tile(formula, photo: photo, problem: problem)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Button(formula.name) { apply(formula) }
                                        .buttonStyle(.bordered)
                                }
                            }
                            .buttonBorderShape(.capsule).controlSize(.small)
                            .disabled(problem != nil || applying)
                            .accessibilityLabel(formula.name)
                            .accessibilityValue(problem ?? "")
                            .accessibilityIdentifier(identifier + ".formula." + formula.name)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func tile(_ formula: Formula, photo: LibraryPhoto, problem: String?) -> some View {
        VStack(spacing: 4) {
            Group {
                if problem == nil, let preview = library.preview(photo, applying: formula) {
                    PhotoThumbnail(photo: preview, images: library.images, showsBadges: false)
                } else {
                    Color(uiColor: .secondarySystemBackground).overlay {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 56, height: 70).clipShape(.rect(cornerRadius: 6))
            Text(formula.name).font(.caption2).lineLimit(1).frame(width: 64)
        }
        .contentShape(.rect)
    }
}

/// Name a look and choose what it carries. Crop and rotation are never saved.
struct SaveFormulaSheet: View {
    let library: PhotoLibrary
    let recipe: EditRecipe
    @State private var name = ""
    @State private var note = ""
    @State private var selection: Set<EditRecipe.Part>
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var naming: Bool
    @Environment(\.dismiss) private var dismiss
    private let available: [EditRecipe.Part]

    init(library: PhotoLibrary, recipe: EditRecipe) {
        self.library = library
        self.recipe = recipe
        available = LookClip(recipe).parts
        // The Look and any Darkroom travel by default; exposure belongs to this photo.
        _selection = State(initialValue: Set(available).subtracting([.exposure]))
    }
    private var chosen: Set<EditRecipe.Part> { selection.intersection(available) }

    var body: some View {
        let names = recipe.lookNames(luts: library.luts)
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "formula.name", defaultValue: "Name"), text: $name)
                        .focused($naming).submitLabel(.done)
                        .accessibilityIdentifier("formula.save.name")
                    TextField(
                        String(localized: "formula.notes", defaultValue: "Notes"), text: $note, axis: .vertical
                    )
                    .lineLimit(1...4).accessibilityIdentifier("formula.save.note")
                } footer: {
                    Text([names.film, names.print].compactMap { $0 }.joined(separator: " → "))
                }
                Section {
                    PartToggles(available: available, selection: $selection, identifier: "formula.save.part")
                } header: {
                    Text(String(localized: "formula.include", defaultValue: "Include"))
                } footer: {
                    Text(
                        String(
                            localized: "formula.save.framing_note",
                            defaultValue: "Crop and rotation are never saved in a formula."))
                }
            }
            .navigationTitle(String(localized: "formula.new", defaultValue: "New Formula"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        String(localized: "common.cancel", defaultValue: "Cancel"), systemImage: "xmark"
                    ) { dismiss() }.labelStyle(.iconOnly).accessibilityIdentifier("formula.save.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.save", defaultValue: "Save"), action: save)
                        .disabled(
                            saving || chosen.isEmpty
                                || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .accessibilityIdentifier("formula.save.confirm")
                        .overlay { if saving { ProgressView().controlSize(.small) } }
                }
            }
            .onAppear { naming = true }
            .failureAlert(String(localized: "formula.new", defaultValue: "New Formula"), message: $failure)
        }
        .presentationDetents([.medium, .large])
    }
    private func save() {
        saving = true
        Task {
            do {
                let references = library.luts.items.map { Formula.LUT(id: $0.id, name: $0.name, size: $0.size) }
                try await library.formulae.save(
                    Formula(name: name, note: note, parts: chosen, from: recipe, luts: references))
                dismiss()
            } catch { failure = error.localizedDescription }
            saving = false
        }
    }
}

enum ManagerTab: String, CaseIterable, Identifiable {
    case formulae, luts
    var id: Self { self }
    var title: String {
        switch self {
        case .formulae: String(localized: "formula.formulae", defaultValue: "Formulae")
        case .luts: String(localized: "lut.luts", defaultValue: "LUTs")
        }
    }
}

/// Formulae and the LUTs they may call for: two lists behind one button.
struct LibraryManagerView: View {
    let library: PhotoLibrary
    @State private var tab = ManagerTab.formulae
    var body: some View {
        Group {
            switch tab {
            case .formulae: FormulaLibraryView(library: library, tab: $tab)
            case .luts: LUTLibraryView(library: library, tab: $tab)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ManagerTabPicker: View {
    @Binding var tab: ManagerTab
    var body: some View {
        Picker(String(localized: "formula.manager", defaultValue: "Formulae and LUTs"), selection: $tab) {
            ForEach(ManagerTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).frame(width: 190).accessibilityIdentifier("manager.tab")
    }
}

/// The same native list as the LUT manager: search, select, rename, reorder and delete.
struct FormulaLibraryView: View {
    let library: PhotoLibrary
    @Binding var tab: ManagerTab
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<UUID>()
    @State private var editing = false
    @State private var search = ""
    @State private var confirmDelete = false
    @State private var working = false
    @State private var failure: String?
    @State private var renaming: Formula?
    @State private var name = ""
    @State private var note = ""
    @State private var showImport = false
    @State private var arrival: FormulaArrival?
    @State private var path: [UUID] = []
    private var formulae: FormulaLibrary { library.formulae }
    private var matches: [Formula] {
        formulae.items.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List(selection: $selection) {
                ForEach(matches) { formula in
                    if editing {
                        row(formula).tag(formula.id)
                    } else {
                        let favorite = formulae.favorites.contains(formula.id)
                        // A selectable list takes a tap as a selection, so the row pushes its page itself.
                        Button {
                            path.append(formula.id)
                        } label: {
                            HStack {
                                row(formula)
                                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary).accessibilityHidden(true)
                            }
                        }
                        .foregroundStyle(.primary).accessibilityIdentifier("formula.row." + formula.name)
                        .contextMenu {
                            ShareLink(
                                item: formulae.file(formula),
                                preview: SharePreview(formula.name, image: Image(systemName: "flask"))
                            ) {
                                Label(
                                    String(localized: "export.share", defaultValue: "Share"),
                                    systemImage: "square.and.arrow.up")
                            }
                            Button(String(localized: "lut.rename", defaultValue: "Rename"), systemImage: "pencil") {
                                rename(formula)
                            }
                            Button(
                                String(localized: "formula.duplicate", defaultValue: "Duplicate"),
                                systemImage: "plus.square.on.square"
                            ) {
                                run {
                                    try await formulae.duplicate(
                                        formula.id,
                                        name: String(
                                            String(
                                                localized: "formula.duplicate_name",
                                                defaultValue: "\(formula.name) copy"
                                            ).prefix(80)))
                                }
                            }
                            favoriteButton(formula, favorite)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(String(localized: "lut.rename", defaultValue: "Rename")) { rename(formula) }
                                .tint(.gray)
                        }
                        .swipeActions(edge: .leading) { favoriteButton(formula, favorite).tint(.yellow) }
                    }
                }
                .onMove { offsets, destination in
                    guard search.isEmpty, !working else { return }
                    run { try await formulae.move(from: offsets, to: destination) }
                }
                .moveDisabled(!search.isEmpty || working)
            }
            .environment(\.editMode, .constant(editing ? .active : .inactive))
            .overlay {
                if formulae.items.isEmpty {
                    ContentUnavailableView(
                        String(localized: "formula.empty", defaultValue: "No Formulae"),
                        systemImage: "flask",
                        description: Text(
                            String(
                                localized: "formula.empty_hint",
                                defaultValue: "Save a look as a formula from a photo’s information panel.")))
                }
            }
            .navigationDestination(for: UUID.self) { FormulaDetailView(library: library, id: $0) }
            .searchable(text: $search)
            .navigationTitle(String(localized: "formula.formulae", defaultValue: "Formulae"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "common.close", defaultValue: "Close"), systemImage: "xmark") {
                        dismiss()
                    }
                    .labelStyle(.iconOnly).buttonBorderShape(.circle)
                    .accessibilityIdentifier("formula.library.close")
                }
                ToolbarItem(placement: .principal) { ManagerTabPicker(tab: $tab) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(
                        editing
                            ? String(localized: "common.cancel", defaultValue: "Cancel")
                            : String(localized: "common.select", defaultValue: "Select")
                    ) {
                        editing.toggle()
                        selection.removeAll()
                    }
                    .disabled(working || formulae.items.isEmpty)
                    .accessibilityIdentifier("formula.library.select")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(String(localized: "common.import", defaultValue: "Import"), systemImage: "plus") {
                        showImport = true
                    }
                    .disabled(working).accessibilityIdentifier("formula.import")
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Text(
                        String(
                            localized: "formula.item_count",
                            defaultValue: "\(formulae.items.count) formulae")
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }.sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button(
                        String(localized: "common.delete", defaultValue: "Delete"),
                        systemImage: "trash", role: .destructive
                    ) { confirmDelete = true }
                    .disabled(!editing || selection.isEmpty || working)
                    .accessibilityIdentifier("formula.delete")
                    .confirmationDialog(
                        String(localized: "formula.delete_confirm", defaultValue: "Delete selected formulae?"),
                        isPresented: $confirmDelete, titleVisibility: .visible
                    ) {
                        Button(
                            String(localized: "formula.delete", defaultValue: "Delete Formulae"),
                            role: .destructive
                        ) {
                            let ids = selection
                            run {
                                try await formulae.remove(ids)
                                selection.removeAll()
                                editing = false
                            }
                        }
                    } message: {
                        Text(
                            String(
                                localized: "formula.delete_message",
                                defaultValue: "Photos already developed with them keep their edits."))
                    }
                }
            }
            .task { do { try await formulae.load() } catch { failure = error.localizedDescription } }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.spektraFormula, .json]) { result in
                do { arrival = try FormulaArrival(url: result.get()) } catch {
                    failure = error.localizedDescription
                }
            }
            .sheet(item: $arrival) { FormulaImportSheet(library: library, arrival: $0) }
            .alert(
                String(localized: "formula.rename", defaultValue: "Rename Formula"),
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
            ) {
                TextField(String(localized: "formula.name", defaultValue: "Name"), text: $name)
                    .accessibilityIdentifier("formula.rename.name")
                TextField(String(localized: "formula.notes", defaultValue: "Notes"), text: $note)
                    .accessibilityIdentifier("formula.rename.note")
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {
                    renaming = nil
                }
                Button(String(localized: "common.save", defaultValue: "Save")) {
                    guard let formula = renaming else { return }
                    let (newName, newNote) = (name, note)
                    renaming = nil
                    run { try await formulae.rename(formula.id, name: newName, note: newNote) }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .failureAlert(String(localized: "formula.formulae", defaultValue: "Formulae"), message: $failure)
        }
    }
    private func row(_ formula: Formula) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if formulae.favorites.contains(formula.id) {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                        .accessibilityLabel(String(localized: "formula.favorite", defaultValue: "Favorite"))
                }
                Text(formula.name).lineLimit(2)
            }
            Text(formula.summary(luts: library.luts)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if formula.parts.count > 1 || !formula.parts.contains(.look) {
                Text(formula.parts.map(\.title).joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !formula.note.isEmpty {
                Text(formula.note).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if let problem = formula.problem(luts: library.luts) {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
            } else if !formula.unreadable.isEmpty {
                Label(
                    String(
                        localized: "formula.newer_parts",
                        defaultValue: "Some settings need a newer SpektraCam."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
    }
    private func favoriteButton(_ formula: Formula, _ favorite: Bool) -> some View {
        Button(
            favorite
                ? String(localized: "formula.unfavorite", defaultValue: "Unfavorite")
                : String(localized: "formula.favorite", defaultValue: "Favorite"),
            systemImage: favorite ? "star.slash" : "star"
        ) { run { try await formulae.setFavorite(formula.id, !favorite) } }
    }
    private func rename(_ formula: Formula) {
        name = formula.name
        note = formula.note
        renaming = formula
    }
    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        Task {
            do { try await work() } catch { failure = error.localizedDescription }
            working = false
        }
    }
}
