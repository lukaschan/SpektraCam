import Foundation

/// A formula carried whole in a link, and so in a QR code. Nothing is uploaded and no server
/// holds it: the formula is the part after `#`, which a browser never sends anywhere.
///
/// `https://runzeni.github.io/spektracam/f#1.<formula>` shows the formula to someone without
/// the app; `spektracam://f#1.<formula>` opens it here. The formula is its stored file with
/// the white space removed, compressed (raw DEFLATE) and written in URL-safe Base64, so
/// settings a newer SpektraCam wrote travel untouched. LUT files never travel this way; the
/// link names the LUTs it needs. Framing is left out: a formula never has any.
nonisolated enum FormulaLink {
    static let page = "https://runzeni.github.io/spektracam/f"
    static let scheme = "spektracam"
    /// How the formula is packed. A later packing takes another number, which this build
    /// declines instead of misreading.
    private static let packing = "1."
    /// The longest link written into a QR code. Past this the code is too fine to scan from
    /// a phone screen or a small print; the file is the way to share such a formula.
    static let codeLimit = 2200
    /// A pasted link may be longer than a code allows, but not without bound.
    static let limit = 12 * 1024

    enum Failure: LocalizedError {
        case notFormula, noCode, tooLarge
        var errorDescription: String? {
            switch self {
            case .notFormula:
                String(localized: "formula.link.not_formula", defaultValue: "This is not a formula link.")
            case .noCode:
                String(
                    localized: "formula.link.no_code",
                    defaultValue: "No formula code was found in this image.")
            case .tooLarge:
                String(
                    localized: "formula.link.too_large",
                    defaultValue: "This formula is too large for a link or code. Share its file instead.")
            }
        }
    }

    /// Recipe fields that belong to one photograph. A formula file holds them empty.
    static let framing = ["crop", "geometry"]
    /// The link for a stored formula file.
    static func url(for file: Data, opensApp: Bool = false) throws -> URL {
        guard var object = try? JSONSerialization.jsonObject(with: file) as? [String: Any] else {
            throw Formula.Failure.unreadable
        }
        object["attachments"] = nil
        if var recipe = object["recipe"] as? [String: Any] {
            for key in framing { recipe[key] = nil }
            object["recipe"] = recipe
        }
        let compact = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let packed = try (compact as NSData).compressed(using: .zlib) as Data
        let text = packed.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let link = (opensApp ? scheme + "://f" : page) + "#" + packing + text
        guard link.utf8.count <= limit, let url = URL(string: link) else { throw Failure.tooLarge }
        return url
    }
    /// Whether text is addressed to this app as a formula, whatever it turns out to hold.
    static func claims(_ text: String) -> Bool {
        guard let mark = text.firstIndex(of: "#") else { return false }
        var address = text[..<mark].lowercased()
        if address.hasPrefix(scheme + ":") { return true }
        for ending in ["/index.html", "/"] where address.hasSuffix(ending) {
            address.removeLast(ending.count)
            break
        }
        return address == page
    }
    /// The formula file a link carries. Throws when the text is not a formula link this build
    /// reads. The file is as untrusted as any other and is read by `Formula(data:)`.
    static func file(from link: String) throws -> Data {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= limit, claims(text), let mark = text.firstIndex(of: "#") else {
            throw Failure.notFormula
        }
        let fragment = text[text.index(after: mark)...]
        guard fragment.hasPrefix(packing) else {
            // A packing this build has never seen is a newer SpektraCam's, not a broken link.
            if let version = fragment.split(separator: ".").first, Int(version) != nil, fragment.contains(".") {
                throw Formula.Failure.newer
            }
            throw Failure.notFormula
        }
        var encoded = fragment.dropFirst(packing.count)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let packed = Data(base64Encoded: encoded), !packed.isEmpty,
            let file = try? (packed as NSData).decompressed(using: .zlib) as Data,
            file.count <= Formula.storedLimit
        else { throw Failure.notFormula }
        return file
    }
}
