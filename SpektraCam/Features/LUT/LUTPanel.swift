import SwiftUI
import UniformTypeIdentifiers

struct LUTPanel: View {
    let session: EditorSession
    let library: PhotoLibrary
    @State private var picker: Slot?
    private enum Slot: Int, Identifiable {
        case first, second
        var id: Self { self }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                slot(
                    .first, title: String(localized: "lut.lut_1", defaultValue: "LUT 1"),
                    value: session.recipe.look.first)
                slot(
                    .second, title: String(localized: "lut.lut_2", defaultValue: "LUT 2"),
                    value: session.recipe.look.second)
                Text(
                    String(
                        localized: "lut.srgb_note",
                        defaultValue: "Use LUTs made for sRGB photos.")
                ).font(.caption).foregroundStyle(.secondary)
                Text(
                    String(
                        localized: "lut.effects_note",
                        defaultValue: "Effects use Portra 400.")
                ).font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
        .sheet(item: $picker) { slot in
            LUTLibraryView(
                library: library,
                assigned: slot == .first
                    ? session.recipe.look.first.id : session.recipe.look.second.id
            ) { id in
                session.update(key: "look.slot.\(slot.rawValue)") {
                    if slot == .first { $0.look.first.id = id } else { $0.look.second.id = id }
                }
            }
        }
    }
    private func slot(_ slot: Slot, title: String, value: EditRecipe.LUTSlot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold))
            Button {
                picker = slot
            } label: {
                HStack {
                    Text(
                        library.luts.name(value.id)
                            ?? (value.id == nil
                                ? String(localized: "lut.choose_lut", defaultValue: "Choose LUT")
                                : String(
                                    localized: "lut.lut_not_found", defaultValue: "LUT not found"))
                    )
                    .lineLimit(2).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.glass).buttonBorderShape(.roundedRectangle(radius: 12))
            .accessibilityIdentifier("lut.slot.\(slot.rawValue)")
            NumericControl(
                title: String(localized: "common.mix", defaultValue: "Mix"),
                value: Binding(
                    get: {
                        (slot == .first
                            ? session.recipe.look.first.mix : session.recipe.look.second.mix)
                            * 100
                    },
                    set: { value in
                        session.update(key: "look.mix.\(slot.rawValue)") {
                            if slot == .first {
                                $0.look.first.mix = value / 100
                            } else {
                                $0.look.second.mix = value / 100
                            }
                        }
                    }), range: 0...100, step: 1, minimum: 0, maximum: 100, unit: "%",
                identifier: "lut.mix.\(slot.rawValue)", defaultValue: slot == .first ? 100 : 0,
                fillOrigin: 0,
                onEditingChanged: {
                    session.setInteraction(key: "look.mix.\(slot.rawValue)", active: $0)
                }
            )
            .disabled(value.id == nil)
        }
    }
}

/// A single native list assigns LUTs and manages the installed files.
struct LUTLibraryView: View {
    let library: PhotoLibrary
    var assigned: String? = nil
    var choose: ((String?) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()
    @State private var editing = false
    @State private var search = ""
    @State private var showImport = false
    @State private var confirmDelete = false
    @State private var working = false
    @State private var progress = String(
        localized: "lut.updating_luts", defaultValue: "Updating LUTs…")
    @State private var failure: String?
    @State private var renaming: InstalledLUT?
    @State private var name = ""
    private var matches: [InstalledLUT] {
        library.luts.items.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                if !editing, let choose {
                    Button(String(localized: "lut.none", defaultValue: "None")) {
                        choose(nil)
                        dismiss()
                    }.foregroundStyle(.primary)
                        .accessibilityIdentifier("lut.none")
                }
                ForEach(matches) { item in
                    if editing {
                        row(item).tag(item.id)
                    } else {
                        Button {
                            if let choose {
                                choose(item.id)
                                dismiss()
                            } else {
                                rename(item)
                            }
                        } label: {
                            row(item)
                        }
                        .foregroundStyle(.primary).accessibilityIdentifier("lut.choose." + item.id)
                        .contextMenu {
                            Button(
                                String(localized: "lut.rename", defaultValue: "Rename"),
                                systemImage: "pencil"
                            ) { rename(item) }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(String(localized: "lut.rename", defaultValue: "Rename")) {
                                rename(item)
                            }.tint(.gray)
                        }
                    }
                }
                .onMove { offsets, destination in
                    guard search.isEmpty, !working else { return }
                    working = true
                    Task {
                        do { try await library.luts.move(from: offsets, to: destination) } catch {
                            failure = error.localizedDescription
                        }
                        working = false
                    }
                }
                .moveDisabled(!search.isEmpty || working)
            }
            .environment(\.editMode, .constant(editing ? .active : .inactive))
            .searchable(text: $search).navigationTitle(
                choose == nil
                    ? String(localized: "lut.manager", defaultValue: "LUT Manager")
                    : String(localized: "lut.luts", defaultValue: "LUTs")
            )
            .navigationBarTitleDisplayMode(.inline)
            .overlay { if working { ImportProgress(text: progress) } }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(
                        String(localized: "common.close", defaultValue: "Close"), systemImage: "xmark"
                    ) { dismiss() }.labelStyle(.iconOnly)
                        .buttonBorderShape(.circle).accessibilityIdentifier("lut.library.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(
                        editing
                            ? String(localized: "common.cancel", defaultValue: "Cancel")
                            : String(localized: "common.select", defaultValue: "Select")
                    ) {
                        editing.toggle()
                        selection.removeAll()
                    }
                    .disabled(working || library.luts.items.isEmpty).accessibilityIdentifier(
                        "lut.library.select")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(
                        String(localized: "common.import", defaultValue: "Import"),
                        systemImage: "plus"
                    ) { showImport = true }
                    .disabled(working).accessibilityIdentifier("lut.import")
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Text(
                        String(
                            localized: "lut.item_count",
                            defaultValue: "\(library.luts.items.count) LUTs")
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
                    .accessibilityIdentifier("lut.delete")
                    .confirmationDialog(
                        String(
                            localized: "lut.delete_confirm",
                            defaultValue: "Delete selected LUTs?"), isPresented: $confirmDelete,
                        titleVisibility: .visible
                    ) {
                        Button(
                            String(localized: "lut.delete_luts", defaultValue: "Delete LUTs"),
                            role: .destructive
                        ) { remove() }
                        Button(
                            String(localized: "lut.force_delete", defaultValue: "Force Delete"),
                            role: .destructive
                        ) { remove(force: true) }
                    } message: {
                        Text(
                            String(
                                localized: "lut.delete_message",
                                defaultValue:
                                    "Delete keeps LUTs used by saved edits or Undo. Force Delete clears those LUT references, including Undo/Redo. Other adjustments and originals stay."
                            )
                        )
                    }
                }
            }
            .fileImporter(
                isPresented: $showImport, allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls): importFiles(urls)
                case .failure(let error): failure = error.localizedDescription
                }
            }
            .task {
                do { try await library.luts.load() } catch { failure = error.localizedDescription }
            }
            .alert(
                String(localized: "lut.rename_lut", defaultValue: "Rename LUT"),
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
            ) {
                TextField(String(localized: "lut.name", defaultValue: "Name"), text: $name)
                    .accessibilityIdentifier("lut.rename.name")
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {
                    renaming = nil
                }
                Button(String(localized: "common.save", defaultValue: "Save")) { saveName() }.disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .failureAlert(String(localized: "lut.lut_library", defaultValue: "LUT Library"), message: $failure)
        }.presentationDetents([.medium, .large])
    }
    private func row(_ item: InstalledLUT) -> some View {
        HStack {
            Text(item.name).lineLimit(2)
            Spacer()
            Text("\(item.size)³").font(.caption2).foregroundStyle(.secondary)
            if item.id == assigned && !editing {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }.contentShape(.rect)
    }
    private func importFiles(_ urls: [URL]) {
        working = true
        Task {
            var errors: [String] = []
            for (index, url) in urls.enumerated() {
                progress = String(
                    localized: "common.import_progress",
                    defaultValue: "Importing \(index + 1) of \(urls.count)…")
                do { try await library.luts.importFile(url) } catch {
                    errors.append(url.lastPathComponent + ": " + error.localizedDescription)
                }
            }
            if !errors.isEmpty { failure = errors.joined(separator: "\n") }
            working = false
        }
    }
    private func rename(_ item: InstalledLUT) {
        name = item.name
        renaming = item
    }
    private func saveName() {
        guard let item = renaming else { return }
        let value = name
        progress = String(localized: "lut.renaming_lut", defaultValue: "Renaming LUT…")
        working = true
        Task {
            do { try await library.luts.rename(item.id, name: value) } catch {
                failure = error.localizedDescription
            }
            working = false
            renaming = nil
        }
    }
    private func remove(force: Bool = false) {
        progress = String(localized: "lut.deleting_luts", defaultValue: "Deleting LUTs…")
        working = true
        let ids = selection
        let protected = library.usedLUTIdentifiers
        Task {
            do {
                if force {
                    try await library.forceDeleteLUTs(ids)
                } else {
                    try await library.luts.remove(ids, protected: protected)
                }
                selection.removeAll()
                editing = false
            } catch { failure = error.localizedDescription }
            working = false
        }
    }
}
