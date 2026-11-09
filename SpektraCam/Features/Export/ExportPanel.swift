import SwiftUI

struct ExportPanel: View {
    private let session: EditorSession?
    @State private var original: OriginalPhotoExporter?
    init(session: EditorSession) {
        self.session = session
        _original = State(initialValue: nil)
    }
    init(originalURL: URL, sourceFilename: String? = nil) {
        session = nil
        _original = State(initialValue: OriginalPhotoExporter(source: originalURL, sourceFilename: sourceFilename))
    }
    @Environment(\.dismiss) private var dismiss
    @State private var format = PhotoExporter.Format.jpeg
    @State private var size = PhotoExporter.Size.full
    @State private var quality = 1.0
    @State private var detent = PresentationDetent.fraction(0.68)
    @State private var sourceDimensions = ""
    @State private var retry = 0
    @State private var url: URL?
    @State private var dimensions = ""
    @State private var failure: String?
    @State private var saving = false
    @State private var saved = false
    @State private var saveFailure: String?
    @State private var renderTask: Task<(URL, Int, Int), Error>?
    private struct Request: Hashable {
        let format: String, size: String, quality: Double, retry: Int
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "export.size", defaultValue: "Size"), selection: $size)
                    {
                        ForEach(PhotoExporter.Size.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Text(
                        size.maximum.map {
                            String(
                                localized: "export.maximum_long_edge_0_px",
                                defaultValue: "Maximum long edge · \($0) px")
                        }
                            ?? (sourceDimensions.isEmpty
                                ? String(
                                    localized: "export.original_resolution_with_crop_applied",
                                    defaultValue: "Original resolution, with crop applied")
                                : String(
                                    localized: "export.original_dimensions_with_crop",
                                    defaultValue:
                                        "Original: \(sourceDimensions) px, with crop applied"))
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Picker(
                        String(localized: "export.format", defaultValue: "Format"),
                        selection: $format
                    ) {
                        ForEach(PhotoExporter.Format.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    if format == .jpeg {
                        Picker(
                            String(localized: "export.jpeg_quality", defaultValue: "JPEG quality"),
                            selection: $quality
                        ) {
                            Text(String(localized: "export.maximum", defaultValue: "Maximum")).tag(
                                1.0)
                            Text(String(localized: "export.high", defaultValue: "High")).tag(0.95)
                            Text(String(localized: "export.standard", defaultValue: "Standard"))
                                .tag(0.85)
                        }.pickerStyle(.segmented)
                    }
                    LabeledContent(
                        String(localized: "export.color_space", defaultValue: "Color space"),
                        value: String(
                            localized: "export.sdr_srgb_8_bit", defaultValue: "SDR · sRGB · 8-bit"))
                    if url != nil {
                        LabeledContent(
                            String(localized: "export.dimensions", defaultValue: "Dimensions"),
                            value: dimensions
                        ).accessibilityIdentifier(
                            "export.dimensions")
                        if let saveFailure {
                            Text(saveFailure).font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if let failure {
                        Text(failure).foregroundStyle(.secondary)
                        Button(String(localized: "common.retry", defaultValue: "Retry")) {
                            retry += 1
                        }
                    } else {
                        ProgressView(
                            String(
                                localized: "export.preparing_image",
                                defaultValue: "Preparing image…"))
                    }
                }
            }
            .disabled(saving)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GlassEffectContainer(spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            shareButton
                            saveButton
                        }
                        VStack(spacing: 10) {
                            shareButton
                            saveButton
                        }
                    }.controlSize(.large).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
            .navigationTitle(String(localized: "common.export", defaultValue: "Export"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done", defaultValue: "Done")) { dismiss() }
                }
            }
            .task(
                id: Request(
                    format: format.rawValue, size: size.rawValue, quality: quality, retry: retry)
            ) {
                await prepareExport()
            }
            .task {
                if let session {
                    sourceDimensions = "\(session.photo.width) × \(session.photo.height)"
                } else if let original, let dimensions = try? await original.dimensions() {
                    sourceDimensions = "\(Int(dimensions.width)) × \(Int(dimensions.height))"
                }
            }
            .onDisappear {
                renderTask?.cancel()
                session?.discardExport()
                if let url { try? FileManager.default.removeItem(at: url) }
                if let original { Task { await original.discard() } }
            }
        }
        .presentationDetents([.fraction(0.68), .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }
    private var saveButton: some View {
        Button(action: saveToPhotos) {
            HStack(spacing: 7) {
                Image(systemName: saved ? "checkmark" : "square.and.arrow.down").foregroundStyle(
                    .white)
                Text(
                    saved
                        ? String(
                            localized: "export.saved_to_photos", defaultValue: "Saved to Photos")
                        : saving
                            ? String(localized: "export.saving", defaultValue: "Saving…")
                            : String(
                                localized: "export.save_to_photos", defaultValue: "Save to Photos"))
            }.padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent).foregroundStyle(.white).disabled(url == nil || saving || saved)
        .accessibilityIdentifier("export.save")
    }
    private var shareButton: some View {
        ShareLink(item: url ?? URL.temporaryDirectory.appendingPathComponent("PreparingPhoto")) {
            Label(
                String(localized: "export.share", defaultValue: "Share"),
                systemImage: "square.and.arrow.up"
            ).padding(.vertical, 4)
                .foregroundStyle(url == nil || saving ? Color.secondary : Color.primary)
        }
        .buttonStyle(.glass).disabled(url == nil || saving)
        .accessibilityIdentifier("export.share")
    }
    private func saveToPhotos() {
        guard let url, !saving, !saved else { return }
        saving = true
        saveFailure = nil
        Task {
            do {
                try await PhotoLibraryWriter.save(url)
                if self.url == url { saved = true }
            } catch { saveFailure = error.localizedDescription }
            saving = false
        }
    }
    private func prepareExport() async {
        let previousURL = url
        url = nil
        failure = nil
        saved = false
        saveFailure = nil
        let previous = renderTask
        previous?.cancel()
        let requestedSize = size
        let requestedFormat = format
        let requestedQuality = quality
        let job = Task {
            if let previous { _ = await previous.result }
            if let previousURL { try? FileManager.default.removeItem(at: previousURL) }
            try Task.checkCancellation()
            if let session {
                return try await session.export(
                    size: requestedSize, format: requestedFormat, quality: requestedQuality)
            }
            guard let original else { throw PhotoExporter.Failure.render }
            return try await original.export(
                size: requestedSize, format: requestedFormat, quality: requestedQuality)
        }
        renderTask = job
        do {
            let result = try await withTaskCancellationHandler {
                try await job.value
            } onCancel: {
                job.cancel()
            }
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: result.0)
                return
            }
            url = result.0
            dimensions = "\(result.1) × \(result.2)"
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
            detent = .large
        }
    }
}
