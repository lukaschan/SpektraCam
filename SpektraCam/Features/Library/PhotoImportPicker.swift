import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Keep imported assets checked while reopening at the system picker's initial position.
struct PhotoImportPicker: UIViewControllerRepresentable {
    let importedIdentifiers: [String]
    let completion: ([PHPickerResult]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> Container {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        configuration.preselectedAssetIdentifiers = importedIdentifiers
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return Container(picker: picker)
    }
    func updateUIViewController(_ controller: Container, context: Context) {}

    final class Container: UIViewController {
        let picker: PHPickerViewController
        private var didResetPosition = false
        init(picker: PHPickerViewController) {
            self.picker = picker
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(picker)
            picker.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(picker.view)
            NSLayoutConstraint.activate([
                picker.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                picker.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                picker.view.topAnchor.constraint(equalTo: view.topAnchor),
                picker.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            picker.didMove(toParent: self)
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if !didResetPosition {
                didResetPosition = true
                picker.scrollToInitialPosition()
            }
        }
    }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoImportPicker
        init(_ parent: PhotoImportPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            parent.completion(results)
        }
    }
    static func file(for result: PHPickerResult) async throws -> LibraryImportFile {
        let provider = result.itemProvider
        let type = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .rawImage) == true
        } ?? provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        }
        guard let type else { throw LibraryFiles.Failure.image }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw LibraryFiles.Failure.image }
                    // The provider's URL expires when its completion returns.
                    continuation.resume(returning: try LibraryImportFile(copying: url))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
