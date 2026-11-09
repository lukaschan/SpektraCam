import Foundation

nonisolated enum PreviewQuality {
    static let libraryKey = "preview.library.maximum"
    static let editorKey = "preview.editor.maximum"
    static let choices = [720, 1080, 2160]
    static let defaultMaximum = 2160
    static func valid(_ value: Int) -> Int { choices.contains(value) ? value : defaultMaximum }
    static var libraryMaximum: Int { valid(UserDefaults.standard.integer(forKey: libraryKey)) }
    static var editorMaximum: Int { valid(UserDefaults.standard.integer(forKey: editorKey)) }
}
