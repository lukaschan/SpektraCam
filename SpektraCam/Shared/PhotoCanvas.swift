import SwiftUI
import UIKit

/// Neutral surround keeps the controls' accent out of the photograph.
enum PhotoTheme {
    static let canvas = Color(
        uiColor: UIColor { traits in
            UIColor(white: traits.userInterfaceStyle == .dark ? 0.16 : 0.94, alpha: 1)
        })
}

/// UIScrollView supplies native pinch, pan and bounce; a standard double-tap toggles fit/zoom.
struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    var topAligned = false
    var topInset: CGFloat = 0
    var zoomedTopInset: CGFloat = 0
    var fitCenterY: CGFloat? = nil
    var label = String(localized: "photo_canvas.edited_photo", defaultValue: "Edited photo")
    var onTap: ((CGPoint) -> Void)?
    /// Sharp pixels for the part of the photo in view, at the resolution the zoom needs.
    var detail: PhotoScrollView.DetailProvider? = nil
    func makeUIView(context: Context) -> PhotoScrollView {
        let view = PhotoScrollView()
        view.delegate = context.coordinator
        context.coordinator.onTap = onTap
        view.photoView.isAccessibilityElement = true
        view.photoView.accessibilityLabel = label
        view.topAligned = topAligned
        view.topInset = topInset
        view.zoomedTopInset = zoomedTopInset
        view.fitCenterY = fitCenterY
        view.photoView.accessibilityTraits = .image
        view.photoView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: String(localized: "photo_canvas.zoom_in", defaultValue: "Zoom in")
            ) { [weak view] _ in
                guard let view else { return false }
                view.setZoomScale(min(view.zoomScale * 2, view.maximumZoomScale), animated: true)
                return true
            },
            UIAccessibilityCustomAction(
                name: String(localized: "photo_canvas.fit_photo", defaultValue: "Fit photo")
            ) { [weak view] _ in
                guard let view else { return false }
                view.setZoomScale(view.minimumZoomScale, animated: true)
                return true
            },
        ]
        view.accessibilityIdentifier = "editor.photo"
        view.contentInsetAdjustmentBehavior = .never
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.bouncesZoom = true
        view.addSubview(view.photoView)
        view.detailView.isHidden = true
        view.detailView.isAccessibilityElement = false
        view.photoView.addSubview(view.detailView)
        let tap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        view.addGestureRecognizer(tap)
        let single = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: tap)
        view.addGestureRecognizer(single)
        return view
    }
    func updateUIView(_ view: PhotoScrollView, context: Context) {
        context.coordinator.onTap = onTap
        view.topAligned = topAligned
        view.topInset = topInset
        view.zoomedTopInset = zoomedTopInset
        view.fitCenterY = fitCenterY
        view.photoView.accessibilityLabel = label
        view.detailProvider = detail
        view.setPhoto(image)
        view.setNeedsLayout()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIView(_ view: PhotoScrollView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.onTap = nil
        view.detailProvider = nil
        view.photoView.image = nil
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var onTap: ((CGPoint) -> Void)?
        @objc func singleTap(_ recognizer: UITapGestureRecognizer) {
            onTap?(recognizer.location(in: recognizer.view?.window))
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? PhotoScrollView)?.photoView
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? PhotoScrollView)?.centerPhoto()
            (scrollView as? PhotoScrollView)?.viewportChanged()
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? PhotoScrollView)?.viewportChanged()
        }
        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PhotoScrollView else { return }
            if view.zoomScale > view.minimumZoomScale * 1.05 {
                view.setZoomScale(view.minimumZoomScale, animated: true)
            } else {
                let scale = min(view.minimumZoomScale * 2.5, view.maximumZoomScale)
                let point = recognizer.location(in: view.photoView)
                let rect = CGRect(
                    x: point.x - view.bounds.width / scale / 2,
                    y: point.y - view.bounds.height / scale / 2,
                    width: view.bounds.width / scale, height: view.bounds.height / scale)
                view.zoom(to: rect, animated: true)
            }
        }
    }
}

final class PhotoScrollView: UIScrollView {
    let photoView = UIImageView()
    var topAligned = false
    var topInset: CGFloat = 0
    var zoomedTopInset: CGFloat = 0
    var fitCenterY: CGFloat? = nil
    private var imageSize = CGSize.zero
    private var lastBounds = CGSize.zero
    private var pendingViewport: (zoom: CGFloat, center: CGPoint)?
    private var replacingImage = false

    // Zoomed detail: the base image stays in place and a sharper render of the visible
    // region is laid over it once the view settles.
    typealias DetailProvider = @MainActor (_ visible: CGRect, _ longEdge: Int) async -> PhotoRenderer.Detail?
    let detailView = UIImageView()
    var detailProvider: DetailProvider? {
        didSet { if detailProvider == nil { clearDetail() } }
    }
    private var detailTask: Task<Void, Never>?
    private var detailGeneration = 0
    private var detailRect = CGRect.null
    private var detailLong = 0
    private var detailAsked = 0
    private func clearDetail() {
        detailTask?.cancel()
        detailTask = nil
        detailView.image = nil
        detailView.isHidden = true
        detailRect = .null
        detailLong = 0
        detailAsked = 0
    }
    func viewportChanged() {
        guard let provider = detailProvider, imageSize.width > 0, imageSize.height > 0,
            !replacingImage
        else { return }
        let long = max(imageSize.width, imageSize.height)
        let needed = Int((long * zoomScale * traitCollection.displayScale).rounded())
        // Until the screen shows more pixels than the preview has, there is nothing to add.
        guard CGFloat(needed) > long * 1.25 else {
            clearDetail()
            return
        }
        let seen = photoView.convert(bounds, from: self).intersection(
            CGRect(origin: .zero, size: imageSize))
        guard !seen.isNull, !seen.isEmpty else { return }
        let unit = CGRect(
            x: seen.minX / imageSize.width, y: seen.minY / imageSize.height,
            width: seen.width / imageSize.width, height: seen.height / imageSize.height)
        if detailView.image != nil, detailRect.contains(unit),
            detailLong * 10 >= needed * 9 || detailAsked >= needed
        {
            return
        }
        detailTask?.cancel()
        let generation = detailGeneration
        detailTask = Task { @MainActor [weak self] in
            // Wait for the gesture or the edit to settle; one render then covers some panning.
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let wide = unit.insetBy(dx: -0.2 * unit.width, dy: -0.2 * unit.height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let detail = await provider(wide, needed), !Task.isCancelled, let self,
                generation == self.detailGeneration, self.imageSize.width > 0
            else { return }
            let size = self.imageSize
            self.detailView.image = UIImage(cgImage: detail.image)
            self.detailView.frame = CGRect(
                x: detail.rect.minX * size.width, y: detail.rect.minY * size.height,
                width: detail.rect.width * size.width, height: detail.rect.height * size.height)
            self.detailView.isHidden = false
            self.detailRect = detail.rect
            self.detailLong = Int(
                Double(detail.image.width) / max(detail.rect.width, 1e-6) * Double(long)
                    / Double(size.width))
            self.detailAsked = needed
        }
    }
    private func viewport() -> (zoom: CGFloat, center: CGPoint) {
        let point = photoView.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: self)
        return (
            zoomScale / max(minimumZoomScale, 1e-6),
            CGPoint(x: point.x / max(imageSize.width, 1), y: point.y / max(imageSize.height, 1))
        )
    }
    func setPhoto(_ image: UIImage) {
        guard photoView.image !== image else { return }
        // The overlay belongs to the previous frame; a new one follows when this settles.
        detailGeneration &+= 1
        clearDetail()
        photoView.preferredImageDynamicRange = .standard
        photoView.image = image
        defer { viewportChanged() }
        if image.size != imageSize {
            // Rendered/cropped and original images can have different pixel sizes. Keep the
            // relative zoom and normalized point when Compare swaps these images.
            if imageSize != .zero { pendingViewport = viewport() }
            replacingImage = true
            imageSize = image.size
            // Remove the old image transform before assigning new pixel dimensions.
            minimumZoomScale = min(minimumZoomScale, 1)
            maximumZoomScale = max(maximumZoomScale, 1)
            setZoomScale(1, animated: false)
            photoView.frame = CGRect(origin: .zero, size: image.size)
            contentSize = image.size
            lastBounds = .zero
            replacingImage = false
            setNeedsLayout()
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return
        }
        if lastBounds != bounds.size {
            let saved = pendingViewport ?? (lastBounds == .zero ? nil : viewport())
            let relative = saved?.zoom ?? 1
            let fit = min(
                bounds.width / imageSize.width, max(1, bounds.height - topInset) / imageSize.height)
            lastBounds = bounds.size
            minimumZoomScale = fit
            maximumZoomScale = max(fit * 8, 1)
            setZoomScale(min(max(fit * relative, fit), maximumZoomScale), animated: false)
            centerPhoto()
            if relative > 1.05, let saved {
                let center = photoView.convert(
                    CGPoint(
                        x: saved.center.x * imageSize.width, y: saved.center.y * imageSize.height),
                    to: self)
                let x = min(
                    max(center.x - bounds.width / 2, -contentInset.left),
                    max(-contentInset.left, contentSize.width - bounds.width + contentInset.right))
                let y = min(
                    max(center.y - bounds.height / 2, -contentInset.top),
                    max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom)
                )
                setContentOffset(CGPoint(x: x, y: y), animated: false)
            } else {
                setContentOffset(
                    CGPoint(x: -contentInset.left, y: -contentInset.top), animated: false)
            }
            pendingViewport = nil
        }
        centerPhoto()
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Decide ownership before a pan starts. Never cancel a live pinch/page transition.
        if gestureRecognizer === panGestureRecognizer, zoomScale <= minimumZoomScale * 1.01 {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
    func centerPhoto() {
        guard !replacingImage else { return }
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let zoomed = zoomScale > minimumZoomScale * 1.05
        let reserve = zoomed ? zoomedTopInset : topInset
        let space = max(0, bounds.height - reserve - contentSize.height)
        let center = !zoomed ? fitCenterY : nil
        let vertical = topAligned ? 0 : center.map {
            min(max($0 - contentSize.height / 2 - reserve, 0), space)
        } ?? space / 2
        let bottom = center != nil && !topAligned ? space - vertical : vertical
        let insets = UIEdgeInsets(
            top: reserve + vertical, left: horizontal, bottom: bottom, right: horizontal)
        if contentInset != insets { contentInset = insets }
        photoView.accessibilityValue = String(
            format: String(
                localized: "photo_canvas.percent_zoom", defaultValue: "%.0f percent zoom"),
            zoomScale / max(minimumZoomScale, 1e-6) * 100)
    }
}

/// The summary's collapsed edge is the same for every photo, even while details expand.
struct PhotoViewport: View {
    let image: UIImage
    var topInset: CGFloat = PhotoInfoPanel.collapsedHeight + 12
    var edited = true
    var topAligned = true
    var usePortraitReference = false
    var onTap: ((CGPoint) -> Void)?
    var detail: PhotoScrollView.DetailProvider? = nil
    var body: some View {
        GeometryReader { proxy in
            ZoomablePhoto(
                image: image, topAligned: topAligned, topInset: topInset,
                zoomedTopInset: topInset > 0 ? 4 : 0,
                fitCenterY: usePortraitReference
                    ? topInset + min(proxy.size.width * 4 / 3, max(1, proxy.size.height - topInset)) / 2
                    : nil,
                label: edited
                    ? String(localized: "photo_canvas.edited_photo", defaultValue: "Edited photo")
                    : String(localized: "photo_canvas.photo", defaultValue: "Photo"), onTap: onTap,
                detail: detail
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
    }
}
