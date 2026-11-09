import SwiftUI
import UIKit

struct AppInformationView: View {
    var importFiles: (() -> Void)? = nil
    @AppStorage(PreviewQuality.libraryKey) private var libraryMaximum = PreviewQuality.defaultMaximum
    @AppStorage(PreviewQuality.editorKey) private var editorMaximum = PreviewQuality.defaultMaximum
    @AppStorage(EditorDefaults.halationKey) private var defaultHalation = true
    @AppStorage(EditorDefaults.grainKey) private var defaultGrain = true
    @AppStorage(EditorDefaults.monochromeGrainKey) private var defaultMonochromeGrain = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private var languageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: code).localizedString(forIdentifier: code) ?? code
    }
    var body: some View {
        NavigationStack {
            List {
                Section("SpektraCam") {
                    Text(
                        String(
                            localized: "about.free_and_open_source_all_editing_features",
                            defaultValue: "Free and open source. All editing features are free."))
                    LabeledContent(
                        String(localized: "about.version", defaultValue: "Version"),
                        value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                            ?? "")
                }
                Section(String(localized: "about.authors", defaultValue: "Authors")) {
                    Link(
                        String(
                            localized: "about.andrea_volpato_spektrafilm",
                            defaultValue: "Andrea Volpato · Spektrafilm"),
                        destination: URL(string: "https://github.com/andreavolpato/spektrafilm")!)
                    Link(
                        String(localized: "about.runze_website", defaultValue: "Runze · Website"),
                        destination: URL(string: "https://runzeni.github.io/")!)
                    Link(
                        String(
                            localized: "about.spektracam_project",
                            defaultValue: "SpektraCam · Project"),
                        destination: URL(string: "https://github.com/runzeni/SpektraCam")!)
                }
                if let importFiles {
                    Section(String(localized: "common.import", defaultValue: "Import")) {
                        Button {
                            dismiss()
                            importFiles()
                        } label: {
                            Label(
                                String(localized: "library.from_files", defaultValue: "From Files"),
                                systemImage: "folder")
                        }
                        .accessibilityIdentifier("about.importFiles")
                    }
                }
                Section(String(localized: "about.settings", defaultValue: "Settings")) {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        LabeledContent(
                            String(localized: "about.language", defaultValue: "Language"),
                            value: languageName)
                    }
                    .accessibilityIdentifier("about.language")
                    .accessibilityHint(
                        String(
                            localized: "about.language_settings_hint",
                            defaultValue: "Change the app language in iPhone Settings."))
                    Picker(
                        String(localized: "about.library_preview", defaultValue: "Library preview"),
                        selection: $libraryMaximum
                    ) {
                        ForEach(PreviewQuality.choices, id: \.self) { Text("\($0) px").tag($0) }
                    }.accessibilityIdentifier("about.libraryPreview")
                    Picker(
                        String(localized: "about.editor_preview", defaultValue: "Editor preview"),
                        selection: $editorMaximum
                    ) {
                        ForEach(PreviewQuality.choices, id: \.self) { Text("\($0) px").tag($0) }
                    }.accessibilityIdentifier("about.editorPreview")
                    Text(
                        String(
                            localized: "about.export_uses_the_original_preview_quality_does",
                            defaultValue:
                                "Export uses the original. Preview quality does not reduce the stored photo."
                        )
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    LabeledContent(
                        String(localized: "about.app_icon", defaultValue: "App icon"),
                        value: "SpektraCam")
                }
                Section(String(localized: "about.new_edit_defaults", defaultValue: "New edit defaults")) {
                    Toggle(String(localized: "effects.halation", defaultValue: "Halation"), isOn: $defaultHalation)
                        .accessibilityIdentifier("about.defaultHalation")
                    Toggle(String(localized: "effects.grain", defaultValue: "Grain"), isOn: $defaultGrain)
                        .accessibilityIdentifier("about.defaultGrain")
                    Toggle(String(localized: "effects.b_w_grain", defaultValue: "B&W Grain"), isOn: $defaultMonochromeGrain)
                        .accessibilityIdentifier("about.defaultMonochromeGrain")
                }
            }
            .navigationTitle(String(localized: "about.about", defaultValue: "About"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        String(localized: "common.done", defaultValue: "Done"), systemImage: "xmark"
                    ) { dismiss() }.labelStyle(.iconOnly)
                }
            }
        }
    }
}
