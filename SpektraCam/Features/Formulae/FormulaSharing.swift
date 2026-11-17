import SwiftUI
import UniformTypeIdentifiers

/// A formula file that has arrived from outside and waits for the user to add it.
struct FormulaArrival: Identifiable {
    let id = UUID()
    let data: Data
    let formula: Formula

    /// A formula file's bytes, from a link, a code or a file.
    init(data: Data) throws {
        self.data = data
        formula = try Formula(data: data, limit: Formula.sharedLimit)
    }
    /// A link that carries the formula, as pasted, opened or read from a code.
    init(link: String) throws { try self.init(data: FormulaLink.file(from: link)) }
    /// Read a file handed to the app: a formula, or a picture of a formula card with its code.
    /// Nothing is added until the user says so.
    init(url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            guard size <= 60 * 1024 * 1024 else { throw FormulaLink.Failure.noCode }
            data = try FormulaCode.file(inImage: Data(contentsOf: url))
            formula = try Formula(data: data, limit: Formula.sharedLimit)
            return
        }
        guard size <= Formula.sharedLimit else { throw Formula.Failure.unreadable }
        data = try Data(contentsOf: url)
        formula = try Formula(data: data, limit: Formula.sharedLimit)
        // The system copies an opened document into the app's Inbox. It has been read.
        if url.deletingLastPathComponent().lastPathComponent == "Inbox" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// What a formula is and what it needs, for the import preview and for its page in the manager.
struct FormulaFacts: View {
    let library: PhotoLibrary
    let formula: Formula
    /// LUT ids carried by the file being previewed.
    var carried: Set<String> = []
    /// Offer to point the formula at another LUT. Only for a formula already in the library.
    var chooseLUT: ((Formula.LUT) -> Void)? = nil
    let importLUT: (Formula.LUT) -> Void

    private var needed: [Formula.LUT] {
        guard formula.parts.contains(.look) else { return [] }
        return [formula.recipe.look.first.id, formula.recipe.look.second.id].compactMap { $0 }.map { id in
            formula.luts.first { $0.id == id } ?? Formula.LUT(id: id, name: "", size: 0)
        }
    }
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(formula.name).font(.headline)
                if !formula.parts.isEmpty {
                    Text(formula.summary(luts: library.luts)).font(.subheadline).foregroundStyle(.secondary)
                }
                if !formula.note.isEmpty { Text(formula.note).font(.footnote).padding(.top, 2) }
            }
            .accessibilityElement(children: .combine).accessibilityIdentifier("formula.facts.title")
            ForEach(formula.parts) { part in
                LabeledContent {
                    Image(systemName: "checkmark").foregroundStyle(.secondary).accessibilityHidden(true)
                } label: {
                    Text(part.title)
                    Text(part.detail)
                }
            }
            if formula.parts.isEmpty || !formula.unreadable.isEmpty {
                Label(
                    formula.parts.isEmpty
                        ? String(
                            localized: "formula.error.newer",
                            defaultValue: "This formula needs a newer version of SpektraCam.")
                        : String(
                            localized: "formula.newer_parts",
                            defaultValue: "Some settings need a newer SpektraCam."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote).foregroundStyle(.orange)
            }
        }
        if !needed.isEmpty {
            Section {
                ForEach(needed, id: \.id) { lut in
                    let installed = library.luts.items.contains { $0.id == lut.id }
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent {
                            Text(
                                installed
                                    ? String(localized: "formula.lut.installed", defaultValue: "Installed")
                                    : carried.contains(lut.id)
                                        ? String(
                                            localized: "formula.lut.included",
                                            defaultValue: "Included in this file")
                                        : String(
                                            localized: "formula.lut.not_installed",
                                            defaultValue: "Not installed")
                            )
                            .foregroundStyle(installed || carried.contains(lut.id) ? Color.secondary : .orange)
                        } label: {
                            Text(
                                library.luts.name(lut.id)
                                    ?? (lut.name.isEmpty
                                        ? String(localized: "formula.lut.unnamed", defaultValue: "Unnamed LUT")
                                        : lut.name))
                            if lut.size > 0 { Text(verbatim: "\(lut.size)³") }
                        }
                        if !installed && !carried.contains(lut.id) {
                            HStack(spacing: 8) {
                                Button(String(localized: "formula.lut.import", defaultValue: "Import LUT…")) {
                                    importLUT(lut)
                                }
                                .accessibilityIdentifier("formula.lut.import")
                                if let chooseLUT {
                                    Button(
                                        String(
                                            localized: "formula.lut.choose",
                                            defaultValue: "Choose Another LUT…")
                                    ) { chooseLUT(lut) }
                                    .accessibilityIdentifier("formula.lut.choose")
                                }
                            }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        }
                    }
                }
            } header: {
                Text(String(localized: "lut.luts", defaultValue: "LUTs"))
            } footer: {
                if needed.contains(where: { lut in !library.luts.items.contains { $0.id == lut.id } }) {
                    Text(
                        String(
                            localized: "formula.lut.note",
                            defaultValue:
                                "A formula cannot be applied until its LUT is installed. Importing the same LUT file links it automatically."
                        ))
                }
            }
        }
    }
}

/// The formula as a procedure, part by part: the same lines its card prints.
struct FormulaProcessSections: View {
    let library: PhotoLibrary
    let formula: Formula
    var body: some View {
        ForEach(FormulaProcess(formula, luts: library.luts).stages) { stage in
            Section(stage.title) {
                ForEach(stage.rows) { row in LabeledContent(row.label, value: row.value) }
            }
        }
    }
}

/// Import a `.cube` for a formula and say plainly when it is not the one the formula needs.
private struct LUTRequest: ViewModifier {
    let library: PhotoLibrary
    @Binding var wanted: Formula.LUT?
    @Binding var failure: String?
    func body(content: Content) -> some View {
        content.fileImporter(
            isPresented: Binding(get: { wanted != nil }, set: { if !$0 { wanted = nil } }),
            allowedContentTypes: [.data]
        ) { result in
            guard let needed = wanted else { return }
            wanted = nil
            switch result {
            case .failure(let error): failure = error.localizedDescription
            case .success(let url):
                Task {
                    do {
                        if try await library.luts.importFile(url).id != needed.id {
                            failure = String(
                                localized: "formula.lut.different",
                                defaultValue:
                                    "That is a different LUT. It was added to your LUTs, but this formula still needs its own."
                            )
                        }
                    } catch { failure = error.localizedDescription }
                }
            }
        }
    }
}

/// The preview shown before a formula from outside is added. Nothing is applied to any photo.
struct FormulaImportSheet: View {
    let library: PhotoLibrary
    let arrival: FormulaArrival
    @Environment(\.dismiss) private var dismiss
    @State private var state = FormulaLibrary.Arrival.new
    @State private var wanted: Formula.LUT?
    @State private var failure: String?
    @State private var working = false
    @State private var confirmReplace = false
    private var carried: [(id: String, name: String, cube: Data)] { Formula.attachments(in: arrival.data) }

    var body: some View {
        NavigationStack {
            List {
                FormulaFacts(
                    library: library, formula: arrival.formula, carried: Set(carried.map(\.id)),
                    importLUT: { wanted = $0 })
                if state != .new {
                    Section {
                        Text(
                            state == .same
                                ? String(
                                    localized: "formula.import.identical",
                                    defaultValue: "This formula is already in your library.")
                                : String(
                                    localized: "formula.import.exists",
                                    defaultValue: "Another version of this formula is already in your library."))
                    }
                }
                FormulaProcessSections(library: library, formula: arrival.formula)
            }
            .navigationTitle(String(localized: "formula.import.title", defaultValue: "Add Formula"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        String(localized: "common.cancel", defaultValue: "Cancel"), systemImage: "xmark"
                    ) { dismiss() }.labelStyle(.iconOnly).accessibilityIdentifier("formula.import.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        state == .same
                            ? String(localized: "common.done", defaultValue: "Done")
                            : String(localized: "formula.import.add", defaultValue: "Add")
                    ) {
                        switch state {
                        case .new: add(.replace)
                        case .same: dismiss()
                        case .changed: confirmReplace = true
                        }
                    }
                    .disabled(working).accessibilityIdentifier("formula.import.add")
                    .confirmationDialog(
                        String(
                            localized: "formula.import.exists",
                            defaultValue: "Another version of this formula is already in your library."),
                        isPresented: $confirmReplace, titleVisibility: .visible
                    ) {
                        Button(String(localized: "formula.import.replace", defaultValue: "Replace")) {
                            add(.replace)
                        }
                        Button(String(localized: "formula.import.keep_both", defaultValue: "Keep Both")) {
                            add(.keepBoth)
                        }
                    }
                }
            }
            .modifier(LUTRequest(library: library, wanted: $wanted, failure: $failure))
            .task { state = await library.formulae.arrival(of: arrival.data) }
            .failureAlert(String(localized: "formula.import.title", defaultValue: "Add Formula"), message: $failure)
        }
        .presentationDetents([.medium, .large])
    }
    private func add(_ conflict: FormulaLibrary.Conflict) {
        working = true
        Task {
            do {
                // The LUT files the sharer chose to send go to the LUT library, checked like any import.
                for lut in carried where !library.luts.items.contains(where: { $0.id == lut.id }) {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "LUT-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: folder) }
                    let name = lut.name.map { "/:\\".contains($0) ? "-" : $0 }
                    let file = folder.appendingPathComponent(name.isEmpty ? lut.id : String(name))
                        .appendingPathExtension("cube")
                    try lut.cube.write(to: file)
                    try await library.luts.importFile(file)
                }
                try await library.formulae.add(arrival.data, conflict: conflict)
                dismiss()
            } catch { failure = error.localizedDescription }
            working = false
        }
    }
}

/// One formula in the manager: what it is, what it needs, and sharing.
struct FormulaDetailView: View {
    let library: PhotoLibrary
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var wanted: Formula.LUT?
    @State private var replacing: Formula.LUT?
    @State private var failure: String?
    @State private var renaming = false
    @State private var name = ""
    @State private var note = ""
    @State private var showCard = false
    @State private var copied = false
    /// The link that carries this formula, or nil when it is too large for one.
    private var link: URL? {
        try? FormulaLink.url(for: Data(contentsOf: library.formulae.fileURL(id)))
    }

    var body: some View {
        if let formula = library.formulae.formula(id) {
            let usesInstalledLUT =
                formula.parts.contains(.look)
                && library.luts.items.contains { formula.recipe.look.identifiers.contains($0.id) }
            List {
                FormulaFacts(
                    library: library, formula: formula, chooseLUT: { replacing = $0 }, importLUT: { wanted = $0 })
                Section {
                    ShareLink(
                        item: library.formulae.file(formula),
                        preview: SharePreview(formula.name, image: Image(systemName: "flask"))
                    ) {
                        Label(
                            usesInstalledLUT
                                ? String(localized: "formula.share.only", defaultValue: "Share Formula Only")
                                : String(localized: "formula.share", defaultValue: "Share Formula"),
                            systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("formula.share")
                    if usesInstalledLUT {
                        ShareLink(
                            item: library.formulae.file(formula, carryingLUTs: library.luts),
                            preview: SharePreview(formula.name, image: Image(systemName: "flask"))
                        ) {
                            Label(
                                String(
                                    localized: "formula.share.with_luts",
                                    defaultValue: "Share with LUT Files"),
                                systemImage: "shippingbox")
                        }
                        .accessibilityIdentifier("formula.share.luts")
                    }
                    if !formula.parts.isEmpty {
                        Button(
                            String(localized: "formula.card.make", defaultValue: "Formula Card…"),
                            systemImage: "qrcode"
                        ) { showCard = true }
                        .accessibilityIdentifier("formula.card.make")
                        Button(
                            copied
                                ? String(localized: "formula.link.copied", defaultValue: "Link Copied")
                                : String(localized: "formula.link.copy", defaultValue: "Copy Link"),
                            systemImage: copied ? "checkmark" : "link"
                        ) {
                            guard let link else { return }
                            UIPasteboard.general.url = link
                            copied = true
                        }
                        .disabled(link == nil).accessibilityIdentifier("formula.link.copy")
                    }
                } footer: {
                    if usesInstalledLUT {
                        Text(
                            String(
                                localized: "formula.share.lut_note",
                                defaultValue:
                                    "Without its LUT files, the other person needs the same LUTs installed. Only include LUT files you are allowed to share."
                            ))
                    }
                }
                FormulaProcessSections(library: library, formula: formula)
            }
            .navigationTitle(formula.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "lut.rename", defaultValue: "Rename")) {
                        name = formula.name
                        note = formula.note
                        renaming = true
                    }
                    .accessibilityIdentifier("formula.detail.rename")
                }
            }
            .modifier(LUTRequest(library: library, wanted: $wanted, failure: $failure))
            .sheet(isPresented: $showCard) { FormulaCardSheet(library: library, formula: formula) }
            .sheet(item: $replacing) { old in
                LUTLibraryView(library: library, assigned: nil) { chosen in
                    guard let chosen, let lut = library.luts.items.first(where: { $0.id == chosen }) else { return }
                    Task {
                        do {
                            try await library.formulae.replaceLUT(
                                in: id, old.id, with: Formula.LUT(id: lut.id, name: lut.name, size: lut.size))
                        } catch { failure = error.localizedDescription }
                    }
                }
            }
            .alert(
                String(localized: "formula.rename", defaultValue: "Rename Formula"), isPresented: $renaming
            ) {
                TextField(String(localized: "formula.name", defaultValue: "Name"), text: $name)
                TextField(String(localized: "formula.notes", defaultValue: "Notes"), text: $note)
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
                Button(String(localized: "common.save", defaultValue: "Save")) {
                    let (newName, newNote) = (name, note)
                    Task {
                        do { try await library.formulae.rename(id, name: newName, note: newNote) } catch {
                            failure = error.localizedDescription
                        }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .failureAlert(String(localized: "formula.formulae", defaultValue: "Formulae"), message: $failure)
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}
