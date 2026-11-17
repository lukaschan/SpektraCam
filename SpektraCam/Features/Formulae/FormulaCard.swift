import SwiftUI

/// The formula as a card: its name, the process in plain words and a code that carries the
/// whole formula. It is an ordinary picture, so it survives every app that strips metadata,
/// and anyone can read the process without SpektraCam.
///
/// The card is drawn at one fixed size in fixed colours: it must come out the same whatever
/// the phone's appearance or text size.
struct FormulaCard: View {
    static let size = CGSize(width: 360, height: 450)
    static let exportScale: CGFloat = 3
    /// Room for the code: four pixels a module up to `FormulaCode.coarseSide`.
    static let codeSide: CGFloat = 152

    let name: String
    let note: String
    let process: FormulaProcess
    let code: FormulaCode?
    var photo: UIImage? = nil

    private static let paper = Color(red: 0.957, green: 0.945, blue: 0.918)
    private static let ink = Color(red: 0.10, green: 0.10, blue: 0.11)
    private var faint: Color { Self.ink.opacity(0.55) }

    private enum Line: Identifiable {
        case title(String)
        case row(String, FormulaProcess.Row)
        case more(Int)
        var id: String {
            switch self {
            case .title(let title): "title." + title
            case .row(let stage, let row): stage + "." + row.id
            case .more: "more"
            }
        }
    }
    /// The process as lines that fit; what does not fit is counted, and is in the code.
    private var lines: [Line] {
        let budget = photo == nil ? 21 : 10
        var all: [Line] = []
        for stage in process.stages {
            all.append(.title(stage.title))
            all += stage.rows.map { .row(stage.id.rawValue, $0) }
        }
        guard all.count > budget else { return all }
        var kept = Array(all.prefix(budget - 1))
        if case .title = kept.last { kept.removeLast() }
        let shown = kept.filter { if case .row = $0 { true } else { false } }.count
        return kept + [.more(process.rowCount - shown)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
                    .frame(width: Self.size.width - 32, height: 168).clipped().padding(.bottom, 12)
            }
            Text(String(localized: "formula.card.kicker", defaultValue: "FORMULA"))
                .font(.system(size: 8.5, weight: .semibold)).kerning(1.6).foregroundStyle(faint)
            Text(name).font(.system(size: 21, weight: .semibold)).lineLimit(photo == nil ? 2 : 1)
                .minimumScaleFactor(0.6).padding(.top, 3)
            if !note.isEmpty {
                Text(note).font(.system(size: 10)).foregroundStyle(faint).lineLimit(photo == nil ? 2 : 1)
                    .padding(.top, 3)
            }
            Rectangle().fill(Self.ink).frame(height: 1).padding(.top, 9).padding(.bottom, 5)
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        switch line {
                        case .title(let title):
                            Text(title.uppercased(with: .current))
                                .font(.system(size: 7.5, weight: .semibold)).kerning(1.2)
                                .foregroundStyle(faint).padding(.top, 6).padding(.bottom, 2)
                        case .row(_, let row):
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(row.label).foregroundStyle(faint).layoutPriority(1)
                                Spacer(minLength: 4)
                                Text(row.value).fontWeight(.medium).monospacedDigit()
                                    .multilineTextAlignment(.trailing)
                            }
                            .font(.system(size: 10.5)).lineLimit(1).minimumScaleFactor(0.75)
                            .frame(height: 15)
                        case .more(let count):
                            Text(
                                String(
                                    localized: "formula.card.more",
                                    defaultValue: "+ \(count) more, all in the code")
                            )
                            .font(.system(size: 9)).foregroundStyle(faint).frame(height: 15)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(verbatim: "SpektraCam")
                        .font(.system(size: 8.5, weight: .semibold)).kerning(0.4).foregroundStyle(faint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                VStack(spacing: 4) {
                    if let code {
                        FormulaCodeView(code: code, pixelScale: Self.exportScale).foregroundStyle(Self.ink)
                            .frame(width: Self.codeSide, height: Self.codeSide)
                        Text(String(localized: "formula.card.scan", defaultValue: "Scan to get this formula"))
                    } else {
                        Text(
                            String(
                                localized: "formula.card.no_code",
                                defaultValue: "Too detailed for a code. Ask for the formula file."))
                    }
                }
                .font(.system(size: 7.5)).foregroundStyle(faint).multilineTextAlignment(.center)
                .frame(width: Self.codeSide)
            }
        }
        .padding(16)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .foregroundStyle(Self.ink)
        .background(Self.paper)
        .environment(\.colorScheme, .light)
        .dynamicTypeSize(.medium)
    }

    /// The card as a picture, 1080 × 1350.
    @MainActor func image() -> UIImage? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = Self.exportScale
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

/// Make a formula's card: choose a photo to show the look on, or none, then share the picture.
struct FormulaCardSheet: View {
    let library: PhotoLibrary
    let formula: Formula
    @Environment(\.dismiss) private var dismiss
    @State private var photoID: UUID?
    @State private var photo: UIImage?
    @State private var working = false
    @State private var file: URL?
    @State private var failure: String?
    /// The formula's code, made once; nil inside when the formula is too large for one.
    @State private var code: FormulaCode??
    /// The newest photos, as candidates to show the look on.
    private var candidates: [LibraryPhoto] { Array(library.photos.suffix(12).reversed()) }

    var body: some View {
        let card = FormulaCard(
            name: formula.name, note: formula.note, process: FormulaProcess(formula, luts: library.luts),
            code: code ?? nil, photo: photo)
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    card.opacity(code == nil ? 0 : 1)
                        .clipShape(.rect(cornerRadius: 4)).shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                        .overlay { if working || code == nil { ProgressView().controlSize(.large) } }
                        .accessibilityElement(children: .ignore).accessibilityLabel(formula.name)
                        .accessibilityIdentifier("formula.card")
                    if !candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "formula.card.photo", defaultValue: "Photo"))
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    choice(nil) {
                                        Color(uiColor: .secondarySystemBackground).overlay {
                                            Image(systemName: "nosign").foregroundStyle(.secondary)
                                        }
                                    }
                                    .accessibilityLabel(String(localized: "formula.card.no_photo", defaultValue: "No photo"))
                                    .accessibilityIdentifier("formula.card.photo.none")
                                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                                        choice(candidate.id) {
                                            PhotoThumbnail(photo: candidate, images: library.images, showsBadges: false)
                                        }
                                        .accessibilityLabel(candidate.filename)
                                        .accessibilityIdentifier("formula.card.photo.\(index)")
                                    }
                                }
                                .padding(.horizontal, 2).padding(.vertical, 3)
                            }
                            .scrollIndicators(.hidden)
                        }
                        .frame(width: FormulaCard.size.width, alignment: .leading)
                    }
                }
                .padding(.vertical, 16).frame(maxWidth: .infinity)
            }
            .navigationTitle(String(localized: "formula.card.title", defaultValue: "Formula Card"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close", defaultValue: "Close"), systemImage: "xmark") {
                        dismiss()
                    }
                    .labelStyle(.iconOnly).accessibilityIdentifier("formula.card.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let file {
                        ShareLink(item: file, preview: SharePreview(formula.name, image: Image(systemName: "flask"))) {
                            Label(String(localized: "export.share", defaultValue: "Share"), systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("formula.card.share")
                    } else {
                        ProgressView()
                    }
                }
            }
            .task(id: photoID) { await prepare() }
            .failureAlert(String(localized: "formula.card.title", defaultValue: "Formula Card"), message: $failure)
        }
    }
    private func choice(_ id: UUID?, @ViewBuilder label: () -> some View) -> some View {
        Button {
            photoID = id
        } label: {
            label().frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 6))
                .overlay {
                    if photoID == id {
                        RoundedRectangle(cornerRadius: 7).inset(by: -2.5).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain).accessibilityAddTraits(photoID == id ? .isSelected : [])
    }
    /// Develop the chosen photo with the formula, then write the card where the share sheet reads it.
    private func prepare() async {
        file = nil
        if code == nil {
            code = .some(
                (try? FormulaLink.url(for: Data(contentsOf: library.formulae.fileURL(formula.id))))
                    .flatMap { FormulaCode($0.absoluteString) })
        }
        var picture: UIImage?
        if let photoID, let chosen = library.photo(photoID) {
            working = true
            defer { working = false }
            do {
                guard let preview = library.preview(chosen, applying: formula) else {
                    throw LibraryFiles.Failure.image
                }
                picture = UIImage(cgImage: try await library.images.image(preview, thumbnail: false))
            } catch {
                if Task.isCancelled { return }
                failure = error.localizedDescription
            }
            if Task.isCancelled { return }
        }
        photo = picture
        let card = FormulaCard(
            name: formula.name, note: formula.note, process: FormulaProcess(formula, luts: library.luts),
            code: code ?? nil, photo: picture)
        guard let data = card.image()?.pngData() else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FormulaCard-" + formula.id.uuidString, isDirectory: true)
        let safe = String(formula.name.map { "/:\\".contains($0) ? "-" : $0 })
        let url = folder.appendingPathComponent(safe).appendingPathExtension("png")
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            file = url
        } catch { failure = error.localizedDescription }
    }
}
