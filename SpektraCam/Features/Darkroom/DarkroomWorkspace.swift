import SwiftUI

/// Finishing work has a separate lifetime from Develop. Paper drags never start a film frame.
struct DarkroomWorkspace: View {
    let session: EditorSession
    var suspended = false
    var adjustCrop: () -> Void = {}
    @State private var image: UIImage?
    @State private var pending = false
    @State private var failure: String?
    @State private var retry = 0
    @State private var interacting = false
    @State private var loupeImage: UIImage?
    @State private var loupeKey: EditRecipe?
    @State private var loupeRefining = false
    @State private var loupeRect: CGRect?
    @State private var loupePatch: PhotoRenderer.Detail?
    @State private var loupePatchKey: EditRecipe?
    /// Edits whose route cannot render a patch fall back to one whole frame for the loupe.
    @State private var wholeFrameKey: EditRecipe?
    @AppStorage("darkroom.loupe") private var showLoupe = true
    /// Enough for 100 % at native resolution on most phones without an export-sized render.
    private static let loupeMaximum = 4096
    private var renderKey: EditRecipe {
        var key = session.recipe
        // The easel's hand-set placement is part of a film-edge render; the paper is not.
        key.printLayout = key.printLayout?.easelOnly
        return key
    }
    private var expectedSize: CGSize {
        let upright = session.recipe.geometry.quarterTurns % 2 == 0
            ? CGSize(width: session.photo.width, height: session.photo.height)
            : CGSize(width: session.photo.height, height: session.photo.width)
        let crop = session.recipe.crop.pixelRect(in: upright).size
        if let layout = session.recipe.renderedFilmEdgeLayout,
           let geometry = FilmEdgeGeometry(imageSize: crop, layout: layout, longEdge: 1000) {
            return CGSize(width: geometry.width, height: geometry.height)
        }
        return crop
    }
    /// Width of the frame `darkroomLoupe` will return, so the loupe can hold its magnification
    /// while that frame is still rendering. A film edge renders up to the loupe maximum; a clean
    /// print is limited by the editor preview.
    private var loupeWidth: CGFloat? {
        let upright = session.recipe.geometry.quarterTurns % 2 == 0
            ? CGSize(width: session.photo.width, height: session.photo.height)
            : CGSize(width: session.photo.height, height: session.photo.width)
        let crop = session.recipe.crop.pixelRect(in: upright).size
        guard crop.width > 0, crop.height > 0, expectedSize.width > 0, expectedSize.height > 0 else { return nil }
        // Patches are rendered at the photo's own resolution, so 100 % means its real pixels.
        let long = max(crop.width, crop.height)
        return (long * expectedSize.width / max(expectedSize.width, expectedSize.height)).rounded()
    }
    private var displayedImage: UIImage { session.recipe.filmEdgeLayout == nil ? session.displayImage : image ?? session.displayImage }
    private var imageMatchesOrientation: Bool {
        abs(log((displayedImage.size.width / displayedImage.size.height) / (expectedSize.width / expectedSize.height))) < 0.015
    }
    var body: some View {
        DarkroomView(image: displayedImage,
            layout: session.binding(\.printLayout, key: "darkroom.layout"),
            edge: Binding(get: { session.recipe.filmEdgeLayout }, set: { layout in
                let imageSize = session.recipe.geometry.quarterTurns % 2 == 0
                    ? CGSize(width: session.photo.width, height: session.photo.height)
                    : CGSize(width: session.photo.height, height: session.photo.width)
                let needsCrop = layout.map { !$0.matchesGate(session.recipe.crop.pixelRect(in: imageSize).size) } ?? false
                session.update(key: "darkroom.edge.layout") { $0.filmEdgeLayout = layout }
                if needsCrop { adjustCrop() }
            }),
            edgeSelection: session.binding(\.filmEdgeSelection, key: "darkroom.edge.selection"),
            resolvedType: session.recipe.resolvedFilmEdgeType,
            adjustCrop: adjustCrop,
            printSourceSize: expectedSize,
            imageReady: imageMatchesOrientation,
            onEditingChanged: { session.setPresentationInteraction(key: "darkroom.layout", active: $0) },
            onEdgeEditingChanged: { active in
                session.setPresentationInteraction(key: "darkroom.edge.layout", active: active)
                interacting = active
            },
            loupeImage: loupeKey == renderKey ? loupeImage : nil,
            loupeRefining: loupeRefining,
            loupeWidth: loupeWidth,
            loupePatch: loupePatchKey == renderKey ? loupePatch : nil,
            onLoupeInspect: { loupeRect = $0 },
            showLoupe: $showLoupe)
        .overlay(alignment: .top) {
            if pending { ProgressView().padding(12).glassEffect().accessibilityIdentifier("darkroom.edge.rendering") }
            if let failure {
                VStack(spacing: 6) {
                    Text(failure).font(.caption)
                    Button(String(localized: "common.retry", defaultValue: "Retry")) { retry += 1 }
                }.padding(12).glassEffect().accessibilityIdentifier("darkroom.edge.failure")
            }
        }
        .task(id: Request(recipe: renderKey, suspended: suspended, retry: retry, interacting: interacting)) {
            pending = false
            failure = nil
            guard !suspended, renderKey.filmEdgeLayout != nil else { return }
            let recipe = renderKey
            pending = true
            do {
                // While a distress slider moves, keep to the quick preview; refine once it settles.
                for maximum in interacting ? [720] : [720, PreviewQuality.editorMaximum] {
                    let frame = try await session.filmEdgePreview(recipe, maximum: maximum)
                    try Task.checkCancellation()
                    image = UIImage(cgImage: frame)
                }
                pending = false
            } catch is CancellationError {
                // The new task owns the indicator. Never publish an obsolete result.
                if !Task.isCancelled { pending = false }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription; pending = false }
            }
        }
        .task(id: PatchRequest(recipe: renderKey, rect: loupeRect, active: showLoupe && !suspended && !interacting)) {
            guard showLoupe, !suspended, !interacting, let rect = loupeRect, wholeFrameKey != renderKey else { return }
            if loupePatchKey == renderKey, let loupePatch, loupePatch.rect.contains(rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))) { return }
            let recipe = renderKey
            do {
                // Follow the lens once it rests; a wider patch then covers small moves.
                try await Task.sleep(for: .milliseconds(120))
                while pending { try await Task.sleep(for: .milliseconds(100)) }
                loupeRefining = true
                defer { loupeRefining = false }
                let wide = rect.insetBy(dx: -0.6 * rect.width, dy: -0.6 * rect.height)
                if let patch = await session.loupePatch(recipe, visible: wide) {
                    try Task.checkCancellation()
                    loupePatch = patch
                    loupePatchKey = recipe
                } else if !Task.isCancelled {
                    wholeFrameKey = recipe
                }
            } catch {}
        }
        .task(id: LoupeRequest(recipe: renderKey, active: showLoupe && !suspended && !interacting && wholeFrameKey == renderKey)) {
            guard showLoupe, !suspended, !interacting, wholeFrameKey == renderKey, loupeKey != renderKey else { return }
            let recipe = renderKey
            do {
                // Let the regular preview finish first; the loupe is a refinement, never a race.
                try await Task.sleep(for: .milliseconds(350))
                while pending { try await Task.sleep(for: .milliseconds(150)) }
                loupeRefining = true
                defer { loupeRefining = false }
                let frame = try await session.darkroomLoupe(recipe, maximum: Self.loupeMaximum)
                try Task.checkCancellation()
                loupeImage = UIImage(cgImage: frame)
                loupeKey = recipe
            } catch {
                // Cancelled or over the memory budget: the loupe keeps magnifying the preview.
            }
        }
    }
    private struct Request: Equatable { let recipe: EditRecipe; let suspended: Bool; let retry: Int; let interacting: Bool }
    private struct LoupeRequest: Equatable { let recipe: EditRecipe; let active: Bool }
    private struct PatchRequest: Equatable { let recipe: EditRecipe; let rect: CGRect?; let active: Bool }
}
