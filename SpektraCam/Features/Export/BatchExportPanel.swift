import Combine
import SwiftUI
import UIKit

struct BatchExportPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: BatchExportModel
    @State private var size = PhotoExporter.Size.full
    @State private var format = PhotoExporter.Format.jpeg
    @State private var quality = 0.95
    @State private var sharing = false

    init(items: [BatchExportItem], library: PhotoLibrary) {
        _model = State(initialValue: BatchExportModel(items: items, library: library))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let reason = model.stopReason, !model.running {
                        Text(reason).font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker(String(localized: "export.size", defaultValue: "Size"), selection: $size)
                    {
                        ForEach(PhotoExporter.Size.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
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
                    Text(
                        String(
                            localized: "export.sdr_srgb_8_bit", defaultValue: "SDR · sRGB · 8-bit")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }.disabled(model.running || model.remainingCount == 0)
                Section {
                    Text(
                        String(
                            localized: "batch.memory_policy",
                            defaultValue:
                                "Photos export one at a time. If a photo needs more memory, the others continue. Choose a smaller size to retry failed photos; completed photos will not export again."
                        )
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                    if model.running {
                        ProgressView(
                            value: Double(model.completedCount), total: Double(model.items.count))
                        Button(
                            String(localized: "common.cancel", defaultValue: "Cancel"),
                            role: .cancel
                        ) {
                            model.cancel()
                        }
                    } else if model.readyURLs.isEmpty {
                        Button(
                            String(
                                localized: "export.save_to_photos", defaultValue: "Save to Photos")
                        ) {
                            model.start(size: size, format: format, quality: quality, save: true)
                        }.disabled(model.remainingCount == 0).accessibilityIdentifier("batch.save")
                        Button(
                            String(
                                localized: "batch.prepare_share",
                                defaultValue: "Prepare for Sharing")
                        ) {
                            model.start(size: size, format: format, quality: quality, save: false)
                        }.disabled(model.remainingCount == 0).accessibilityIdentifier(
                            "batch.prepareShare")
                    }
                    if !model.readyURLs.isEmpty {
                        Button(String(localized: "export.share", defaultValue: "Share")) {
                            sharing = true
                        }
                        .disabled(model.running).accessibilityIdentifier("batch.share")
                        Button(
                            String(
                                localized: "batch.clear_prepared",
                                defaultValue: "Clear Prepared Files")
                        ) { model.cleanFiles() }
                        .disabled(model.running)
                        if model.failureCount > 0 {
                            Button(
                                String(
                                    localized: "batch.retry_failed",
                                    defaultValue: "Retry Failed Photos")
                            ) {
                                model.start(
                                    size: size, format: format, quality: quality, save: false)
                            }.disabled(model.running)
                        }
                    }
                }
                Section {
                    ForEach(model.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).lineLimit(1)
                            if model.activeID == item.id {
                                ProgressView(
                                    String(
                                        localized: "export.preparing_image",
                                        defaultValue: "Preparing image…"))
                            } else {
                                switch model.outcomes[item.id] {
                                case .saved?:
                                    Text(
                                        String(
                                            localized: "export.saved_to_photos",
                                            defaultValue: "Saved to Photos"))
                                case .shared?:
                                    Text(String(localized: "batch.shared", defaultValue: "Shared"))
                                case .ready?:
                                    Text(
                                        String(
                                            localized: "batch.ready", defaultValue: "Ready to share"
                                        ))
                                case .failed(let message)?:
                                    Text(message).foregroundStyle(.secondary)
                                case nil:
                                    if let assessment = model.assessments[item.id] {
                                        Text(assessment).foregroundStyle(.secondary)
                                    } else {
                                        Text(
                                            String(
                                                localized: "batch.pending", defaultValue: "Pending")
                                        )
                                    }
                                }
                            }
                        }.font(.subheadline)
                    }
                }
            }
            .navigationTitle(String(localized: "batch.title", defaultValue: "Batch Export"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done", defaultValue: "Done")) { dismiss() }
                        .disabled(model.running || sharing)
                }
            }
            .interactiveDismissDisabled(model.running || sharing)
            .sheet(isPresented: $sharing) {
                ExportActivitySheet(urls: model.readyURLs) { if $0 { model.shared() } }
            }
            .task(id: size) { await model.assess(size: size) }
            .onChange(of: scenePhase) { _, phase in if phase == .background { model.cancel() } }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification)
            ) { _ in
                model.memoryWarning()
            }
            .onDisappear { if !sharing { model.close() } }
        }
    }
}

private struct ExportActivitySheet: UIViewControllerRepresentable {
    let urls: [URL]
    let completion: @MainActor (Bool) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            Task { @MainActor in completion(completed) }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
