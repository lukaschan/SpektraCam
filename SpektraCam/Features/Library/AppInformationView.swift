import SwiftUI
import UIKit

/// Public pages for the project. The privacy policy and support pages are the same
/// URLs entered in App Store Connect.
enum AppLinks {
    static let project = URL(string: "https://github.com/runzeni/SpektraCam")!
    static let privacy = URL(string: "https://github.com/runzeni/SpektraCam/blob/main/PRIVACY.md")!
    static let support = URL(string: "https://github.com/runzeni/SpektraCam/issues")!
    static let spektrafilm = URL(string: "https://github.com/andreavolpato/spektrafilm")!
    static let author = URL(string: "https://runzeni.github.io/")!
}

struct AppInformationView: View {
    var importFiles: (() -> Void)? = nil
    @AppStorage(PreviewQuality.libraryKey) private var libraryMaximum = PreviewQuality.defaultMaximum
    @AppStorage(PreviewQuality.editorKey) private var editorMaximum = PreviewQuality.defaultMaximum
    @AppStorage(EditorDefaults.halationKey) private var defaultHalation = true
    @AppStorage(EditorDefaults.grainKey) private var defaultGrain = true
    @AppStorage(EditorDefaults.monochromeGrainKey) private var defaultMonochromeGrain = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var version: String {
        let info = Bundle.main.infoDictionary
        let release = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(release) (\(build))"
    }
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
                            localized: "about.free_and_open_source",
                            defaultValue: "Free and open source. All editing features are free."))
                    LabeledContent(
                        String(localized: "about.version", defaultValue: "Version"), value: version)
                }
                Section(String(localized: "about.authors", defaultValue: "Authors")) {
                    Link(
                        String(
                            localized: "about.spektrafilm_link",
                            defaultValue: "Andrea Volpato · Spektrafilm"),
                        destination: AppLinks.spektrafilm)
                    Link(
                        String(localized: "about.author_website", defaultValue: "Runze · Website"),
                        destination: AppLinks.author)
                    Link(
                        String(localized: "about.project_link", defaultValue: "SpektraCam · Project"),
                        destination: AppLinks.project)
                }
                if let importFiles {
                    Section(String(localized: "common.import", defaultValue: "Import")) {
                        Button(
                            String(localized: "library.from_files", defaultValue: "From Files"),
                            systemImage: "folder"
                        ) {
                            dismiss()
                            importFiles()
                        }
                        .accessibilityIdentifier("about.importFiles")
                    }
                }
                Section(String(localized: "about.settings", defaultValue: "Settings")) {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        LabeledContent(
                            String(localized: "about.language", defaultValue: "Language"),
                            value: languageName)
                    }
                    .accessibilityIdentifier("about.language")
                    .accessibilityHint(
                        String(
                            localized: "about.language_settings_hint",
                            defaultValue: "Change the app language in Settings."))
                    previewPicker(
                        String(localized: "about.library_preview", defaultValue: "Library preview"),
                        selection: $libraryMaximum, identifier: "about.libraryPreview")
                    previewPicker(
                        String(localized: "about.editor_preview", defaultValue: "Editor preview"),
                        selection: $editorMaximum, identifier: "about.editorPreview")
                    footnote(
                        String(
                            localized: "about.preview_quality_note",
                            defaultValue:
                                "Export uses the original. Preview quality does not reduce the stored photo."
                        ))
                }
                Section(String(localized: "about.new_edit_defaults", defaultValue: "New edit defaults")) {
                    Toggle(String(localized: "effects.halation", defaultValue: "Halation"), isOn: $defaultHalation)
                        .accessibilityIdentifier("about.defaultHalation")
                    Toggle(String(localized: "effects.grain", defaultValue: "Grain"), isOn: $defaultGrain)
                        .accessibilityIdentifier("about.defaultGrain")
                    Toggle(String(localized: "effects.b_w_grain", defaultValue: "B&W Grain"), isOn: $defaultMonochromeGrain)
                        .accessibilityIdentifier("about.defaultMonochromeGrain")
                }
                Section(String(localized: "about.legal", defaultValue: "Legal")) {
                    footnote(
                        String(
                            localized: "about.privacy_summary",
                            defaultValue:
                                "No accounts, ads or tracking. Photos, edits and LUTs stay on this device."))
                    Link(
                        String(localized: "about.privacy_policy", defaultValue: "Privacy Policy"),
                        destination: AppLinks.privacy
                    )
                    .accessibilityIdentifier("about.privacy")
                    Link(
                        String(localized: "about.support", defaultValue: "Support"),
                        destination: AppLinks.support
                    )
                    .accessibilityIdentifier("about.support")
                    NavigationLink(String(localized: "about.licenses", defaultValue: "Licenses")) {
                        LicensesView()
                    }
                    .accessibilityIdentifier("about.licenses")
                    footnote(
                        String(
                            localized: "about.simulation_disclaimer",
                            defaultValue:
                                "Film and paper names identify the published data each simulation is modelled on. SpektraCam is not affiliated with or endorsed by their manufacturers."
                        ))
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

    private func previewPicker(_ title: String, selection: Binding<Int>, identifier: String) -> some View {
        Picker(title, selection: selection) {
            ForEach(PreviewQuality.choices, id: \.self) { Text(verbatim: "\($0) px").tag($0) }
        }.accessibilityIdentifier(identifier)
    }
    private func footnote(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }
}

/// The licences that ship in the bundle: the app's GPLv3, the spektrafilm profile
/// licence (CC BY-SA 4.0) and the third-party notices.
private struct LicensesView: View {
    private static let documents = [
        ("SpektraCam · GPLv3", "LICENSE"),
        ("spektrafilm · CC BY-SA 4.0", "SPEKTRAFILM_LICENSE"),
        ("Colour · Random123", "ThirdPartyNotices"),
    ]
    var body: some View {
        List {
            ForEach(Self.documents, id: \.1) { title, resource in
                NavigationLink(title) { LicenseText(title: title, resource: resource) }
            }
            Link(
                String(localized: "about.source_code", defaultValue: "Source Code"),
                destination: AppLinks.project)
        }
        .navigationTitle(String(localized: "about.licenses", defaultValue: "Licenses"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseText: View {
    let title: String
    let resource: String
    @State private var text = ""
    var body: some View {
        ScrollView {
            Text(text).font(.caption.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "txt") else { return }
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }
}
