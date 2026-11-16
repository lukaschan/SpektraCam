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

    private func binding(_ part: EditRecipe.Part) -> Binding<Bool> {
        switch part {
        case .look: $look
        case .exposure: $exposure
        case .darkroom: $darkroom
        }
    }
    private var chosen: Set<EditRecipe.Part> {
        Set(clip.parts.filter { binding($0).wrappedValue })
    }
    private var names: (film: String, print: String?) {
        let recipe = clip.recipe
        guard recipe.look.enabled else {
            return (String(localized: "photo.original", defaultValue: "Original"), nil)
        }
        if recipe.look.mode == .lut {
            let luts = [recipe.look.first.id, recipe.look.second.id].compactMap { library.luts.name($0) }
            return (
                "3D LUT",
                luts.isEmpty
                    ? String(localized: "lut.none_selected", defaultValue: "No LUT selected")
                    : luts.joined(separator: " · ")
            )
        }
        return (
            FilmStock.films.first { $0.id == recipe.filmID }?.name
                ?? String(localized: "film_stock.film", defaultValue: "Film"),
            recipe.bypassesPrint
                ? String(localized: "develop.direct_scan", defaultValue: "Direct scan")
                : FilmStock.prints.first { $0.id == recipe.printID }?.name
                    ?? String(localized: "develop.print", defaultValue: "Print")
        )
    }

    var body: some View {
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
                    ForEach(EditRecipe.Part.allCases) { part in
                        let available = clip.parts.contains(part)
                        Toggle(
                            isOn: available ? binding(part) : .constant(false)
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(part.title)
                                Text(part.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!available)
                        .accessibilityIdentifier("look.paste.part." + part.rawValue)
                    }
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
