import SwiftUI

struct EditorInfoBar: View {
    let session: EditorSession
    let showingOriginal: Bool
    var location: String? = nil
    var onInteraction: (() -> Void)? = nil
    private var filmName: String {
        if !session.recipe.look.enabled {
            return String(localized: "photo.original", defaultValue: "Original")
        }
        if session.recipe.look.mode == .lut { return "3D LUT" }
        return FilmStock.films.first { $0.id == session.recipe.filmID }?.name
            ?? String(localized: "editor_info_bar.film", defaultValue: "Film")
    }
    private var printName: String {
        if !session.recipe.look.enabled { return session.photo.metadata.formatLabel }
        if session.recipe.look.mode == .lut {
            let names = [session.recipe.look.first.id, session.recipe.look.second.id].compactMap {
                session.luts?.name($0)
            }
            return names.isEmpty
                ? String(
                    localized: "editor_info_bar.no_lut_selected", defaultValue: "No LUT selected")
                : names.joined(separator: " · ")
        }
        return session.recipe.bypassesPrint
            ? String(localized: "editor_info_bar.direct_scan", defaultValue: "Direct scan")
            : FilmStock.prints.first { $0.id == session.recipe.printID }?.name
                ?? String(localized: "editor_info_bar.print", defaultValue: "Print")
    }
    var body: some View {
        VStack(spacing: 2) {
            PhotoInfoPanel(
                title: filmName, subtitle: printName, metadata: session.photo.metadata,
                location: location,
                histogram: showingOriginal ? session.originalHistogram : session.histogram,
                identifier: "editor", onInteraction: onInteraction)
            if session.previewWasReduced {
                Text(
                    String(
                        localized: "editor.preview_reduced",
                        defaultValue: "Preview reduced to 720 px to fit available memory.")
                )
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
