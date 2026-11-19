import SwiftUI

/// Copy, paste and undo for the look of a photo, as shown in the information panel.
struct LookActions {
    var canCopy = false
    var canPaste = false
    var canUndo = false
    let copy: () -> Void
    let paste: () -> Void
    var undo: () -> Void = {}
}

struct LookActionRow: View {
    let actions: LookActions
    let identifier: String
    @State private var copies = 0
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sensoryFeedback(.success, trigger: copies)
    }
    @ViewBuilder private var buttons: some View {
        Button(String(localized: "look.copy", defaultValue: "Copy Look")) {
            actions.copy()
            copies += 1
        }
        .disabled(!actions.canCopy).accessibilityIdentifier(identifier + ".look.copy")
        Button(String(localized: "look.paste", defaultValue: "Paste Look…"), action: actions.paste)
            .disabled(!actions.canPaste).accessibilityIdentifier(identifier + ".look.paste")
        if actions.canUndo {
            Button(String(localized: "look.undo_paste", defaultValue: "Undo Paste"), action: actions.undo)
                .accessibilityIdentifier(identifier + ".look.undo")
        }
    }
}

extension EditRecipe {
    /// Film over print, as the information panel names a look.
    func lookNames(luts: LUTLibrary) -> (film: String, print: String?) {
        guard look.enabled else {
            return (String(localized: "photo.original", defaultValue: "Original"), nil)
        }
        if look.mode == .lut {
            let names = [look.first.id, look.second.id].compactMap { luts.name($0) }
            return (
                "3D LUT",
                names.isEmpty
                    ? String(localized: "lut.none_selected", defaultValue: "No LUT selected")
                    : names.joined(separator: " · ")
            )
        }
        return (
            FilmStock.films.first { $0.id == filmID }?.name
                ?? String(localized: "film_stock.film", defaultValue: "Film"),
            bypassesPrint
                ? String(localized: "develop.direct_scan", defaultValue: "Direct scan")
                : FilmStock.prints.first { $0.id == printID }?.name
                    ?? String(localized: "develop.print", defaultValue: "Print")
        )
    }
}

/// One switch per part. A part the source does not have is shown off and disabled.
struct PartToggles: View {
    let available: [EditRecipe.Part]
    @Binding var selection: Set<EditRecipe.Part>
    let identifier: String
    var body: some View {
        ForEach(EditRecipe.Part.allCases) { part in
            let offered = available.contains(part)
            Toggle(
                isOn: Binding(
                    get: { offered && selection.contains(part) },
                    set: { if $0 { selection.insert(part) } else { selection.remove(part) } })
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(part.title)
                    Text(part.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!offered)
            .accessibilityIdentifier(identifier + "." + part.rawValue)
        }
    }
}

/// Choose which parts of the copied look to paste. Crop and rotation are never offered.
struct PasteLookSheet: View {
    let library: PhotoLibrary
    let clip: LookClip
    /// How many photos receive the look. One hides the count.
    var count = 1
    let paste: (Set<EditRecipe.Part>) -> Void
    @AppStorage("paste.part.look") private var look = true
    @AppStorage("paste.part.exposure") private var exposure = false
    @AppStorage("paste.part.darkroom") private var darkroom = true
    @Environment(\.dismiss) private var dismiss

    /// The last choice is remembered for the next paste.
    private var selection: Binding<Set<EditRecipe.Part>> {
        Binding(
            get: {
                var parts = Set<EditRecipe.Part>()
                if look { parts.insert(.look) }
                if exposure { parts.insert(.exposure) }
                if darkroom { parts.insert(.darkroom) }
                return parts
            },
            set: {
                look = $0.contains(.look)
                exposure = $0.contains(.exposure)
                darkroom = $0.contains(.darkroom)
            })
    }
    private var chosen: Set<EditRecipe.Part> { selection.wrappedValue.intersection(clip.parts) }

    var body: some View {
        let names = clip.recipe.lookNames(luts: library.luts)
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        if let photo = clip.sourceID.flatMap(library.photo) {
                            PhotoThumbnail(photo: photo, images: library.images, showsBadges: false)
                                .frame(width: 44, height: 56).clipShape(.rect(cornerRadius: 6))
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(names.film).font(.subheadline.weight(.semibold))
                            if let print = names.print {
                                Text(print).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("look.paste.source")
                }
                Section {
                    PartToggles(available: clip.parts, selection: selection, identifier: "look.paste.part")
                } header: {
                    if count > 1 {
                        Text(String(localized: "library.photo_count", defaultValue: "\(count) photos"))
                    }
                } footer: {
                    Text(
                        String(
                            localized: "look.paste.framing_note",
                            defaultValue: "Crop and rotation stay with each photo."))
                }
            }
            .navigationTitle(String(localized: "look.paste.title", defaultValue: "Paste Look"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        String(localized: "common.cancel", defaultValue: "Cancel"), systemImage: "xmark"
                    ) { dismiss() }.labelStyle(.iconOnly).accessibilityIdentifier("look.paste.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "look.paste.confirm", defaultValue: "Paste")) {
                        let parts = chosen
                        dismiss()
                        paste(parts)
                    }
                    .disabled(chosen.isEmpty).accessibilityIdentifier("look.paste.confirm")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
