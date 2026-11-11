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
    private var renderKey: EditRecipe {
        var key = session.recipe
        key.printLayout = nil
        return key
    }
    private var expectedSize: CGSize {
        let upright = session.recipe.geometry.quarterTurns % 2 == 0
            ? CGSize(width: session.photo.width, height: session.photo.height)
            : CGSize(width: session.photo.height, height: session.photo.width)
        let crop = session.recipe.crop.pixelRect(in: upright).size
        if let layout = session.recipe.filmEdgeLayout,
           let geometry = FilmEdgeGeometry(imageSize: crop, layout: layout, longEdge: 1000) {
            return CGSize(width: geometry.width, height: geometry.height)
        }
        return crop
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
            })
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
    }
    private struct Request: Equatable { let recipe: EditRecipe; let suspended: Bool; let retry: Int; let interacting: Bool }
}
