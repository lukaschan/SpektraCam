import SwiftUI
import UIKit

/// UIKit owns page transitions. Selection changes only when a swipe completes.
struct AlbumPager: UIViewControllerRepresentable {
    let photos: [LibraryPhoto]
    let images: LibraryImages
    @Binding var selection: UUID
    var onTap: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .scroll, navigationOrientation: .horizontal)
        controller.view.backgroundColor = .clear
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.showSelection(in: controller)
        return controller
    }
    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.showSelection(in: controller)
    }
    static func dismantleUIViewController(
        _ controller: UIPageViewController, coordinator: Coordinator
    ) {
        controller.dataSource = nil
        controller.delegate = nil
        coordinator.pages.removeAll()
    }
    final class Page: UIHostingController<AlbumPhotoPage> {
        let photoID: UUID
        var renderKey: String
        init(photo: LibraryPhoto, images: LibraryImages, onTap: @escaping () -> Void) {
            photoID = photo.id
            renderKey = photo.renderKey
            super.init(rootView: AlbumPhotoPage(photo: photo, images: images, onTap: onTap))
            view.backgroundColor = .clear
        }
        @MainActor required dynamic init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }
    }
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate
    {
        var parent: AlbumPager
        var pages: [UUID: Page] = [:]
        private var transitioning = false
        private var requestedDuringTransition: UUID?
        private var transitionSelection: UUID?
        init(_ parent: AlbumPager) { self.parent = parent }
        /// Pages outlive updates, so they call through to the current parent.
        private var tap: () -> Void { { [weak self] in self?.parent.onTap() } }
        private func page(_ photo: LibraryPhoto) -> Page {
            if let page = pages[photo.id] {
                if page.renderKey != photo.renderKey {
                    page.renderKey = photo.renderKey
                    page.rootView = AlbumPhotoPage(photo: photo, images: parent.images, onTap: tap)
                }
                return page
            }
            let page = Page(photo: photo, images: parent.images, onTap: tap)
            pages[photo.id] = page
            return page
        }
        func showSelection(in controller: UIPageViewController) {
            guard !transitioning else {
                if parent.selection != transitionSelection {
                    requestedDuringTransition = parent.selection
                }
                return
            }
            guard let photo = parent.photos.first(where: { $0.id == parent.selection }) else {
                return
            }
            let target = page(photo)
            guard (controller.viewControllers?.first as? Page)?.photoID != photo.id else { return }
            // Filmstrip taps are immediate; they never overlap a native swipe animation.
            controller.setViewControllers([target], direction: .forward, animated: false)
            trim(around: photo.id)
        }
        private func trim(around id: UUID) {
            guard let index = parent.photos.firstIndex(where: { $0.id == id }) else { return }
            let ids = Set(
                parent.photos[max(0, index - 1)...min(parent.photos.count - 1, index + 1)].map(\.id)
            )
            pages = pages.filter { ids.contains($0.key) }
        }
        func pageViewController(
            _ controller: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            neighbor(of: viewController, offset: -1)
        }
        func pageViewController(
            _ controller: UIPageViewController, viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            neighbor(of: viewController, offset: 1)
        }
        private func neighbor(of controller: UIViewController, offset: Int) -> Page? {
            guard let current = controller as? Page,
                let index = parent.photos.firstIndex(where: { $0.id == current.photoID }),
                parent.photos.indices.contains(index + offset)
            else { return nil }
            return page(parent.photos[index + offset])
        }
        func pageViewController(
            _ controller: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            transitioning = true
            transitionSelection = parent.selection
            requestedDuringTransition = nil
        }
        func pageViewController(
            _ controller: UIPageViewController, didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController], transitionCompleted completed: Bool
        ) {
            transitioning = false
            guard let visible = controller.viewControllers?.first as? Page else { return }
            let requested = requestedDuringTransition
            requestedDuringTransition = nil
            transitionSelection = nil
            if let requested {
                parent.selection = requested
                showSelection(in: controller)
            } else {
                parent.selection = visible.photoID
                trim(around: visible.photoID)
            }
        }
    }
}
