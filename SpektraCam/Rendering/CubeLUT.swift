import CryptoKit
import Foundation

/// Adobe Cube: red changes fastest. This first reader accepts 3D tables without 1D shapers.
nonisolated struct CubeLUT: Sendable {
    enum Failure: LocalizedError {
        case format(String)
        case size, missing
        var errorDescription: String? {
            switch self {
            case .format(let reason):
                String(
                    localized: "cube_lut.error.invalid",
                    defaultValue: "Invalid 3D LUT: \(reason)")
            case .size:
                String(
                    localized: "cube_lut.error.requirements",
                    defaultValue:
                        "Use a 3D .cube file with 2 to 65 points per axis and no more than 16 MB.")
            case .missing:
                String(
                    localized: "cube_lut.error.file_missing",
                    defaultValue: "This edit’s LUT file is not available.")
            }
        }
    }
    struct Application: Sendable {
        let cube: CubeLUT
        let mix: Double
    }
    let id: String
    let title: String
    let size: Int
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>
    let values: [SIMD4<Float>]

    init(data: Data, filename: String) throws {
        guard data.count <= 16 * 1024 * 1024 else { throw Failure.size }
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure.format(
                String(localized: "cube_lut.error.encoding", defaultValue: "Use UTF-8 text."))
        }
        var size: Int?
        var name: String?
        var low = SIMD3<Float>.zero
        var high = SIMD3<Float>(repeating: 1)
        var rows: [SIMD4<Float>] = []
        var headers = Set<String>()
        for original in text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")).split(
            whereSeparator: \.isNewline)
        {
            var quoted = false
            let line = original.prefix { char in
                if char == "\"" { quoted.toggle() }
                return char != "#" || quoted
            }.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let words = line.split(whereSeparator: \.isWhitespace)
            guard let key = words.first else { continue }
            if key == "TITLE" {
                guard rows.isEmpty, headers.insert("TITLE").inserted,
                    let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""),
                    first < last
                else {
                    throw Failure.format(
                        String(localized: "cube_lut.error.title", defaultValue: "Check TITLE."))
                }
                name = String(line[line.index(after: first)..<last].prefix(200))
            } else if key == "LUT_3D_SIZE" {
                guard rows.isEmpty, headers.insert(String(key)).inserted, words.count == 2,
                    let count = Int(words[1]), (2...65).contains(count)
                else { throw Failure.size }
                size = count
                rows.reserveCapacity(count * count * count)
            } else if key == "DOMAIN_MIN" || key == "DOMAIN_MAX" {
                guard rows.isEmpty, !headers.contains("LUT_3D_INPUT_RANGE"),
                    headers.insert(String(key)).inserted, words.count == 4
                else {
                    throw Failure.format(
                        String(
                            localized: "cube_lut.error.input_domain",
                            defaultValue: "Check the input domain."))
                }
                let vector = try Self.vector(Array(words.dropFirst()))
                if key == "DOMAIN_MIN" { low = vector } else { high = vector }
            } else if key == "LUT_3D_INPUT_RANGE" {
                guard rows.isEmpty, headers.insert(String(key)).inserted, words.count == 3,
                    !headers.contains("DOMAIN_MIN"), !headers.contains("DOMAIN_MAX"),
                    let a = Float(words[1]), let b = Float(words[2]), a.isFinite, b.isFinite
                else {
                    throw Failure.format(
                        String(
                            localized: "cube_lut.error.input_range",
                            defaultValue: "Check the input range."))
                }
                low = SIMD3(repeating: a)
                high = SIMD3(repeating: b)
            } else if key.hasPrefix("LUT_") {
                throw Failure.format(
                    String(
                        localized: "cube_lut.error.shaper_unsupported",
                        defaultValue: "Only 3D tables without 1D shapers are supported."))
            } else {
                guard let count = size, rows.count < count * count * count else {
                    throw Failure.format(
                        String(
                            localized: "cube_lut.error.table_length",
                            defaultValue: "Check the table length."))
                }
                let v = try Self.vector(words)
                rows.append(SIMD4(v.x, v.y, v.z, 1))
            }
        }
        guard let size, rows.count == size * size * size else {
            throw Failure.format(
                String(
                    localized: "cube_lut.error.incomplete",
                    defaultValue: "The table is incomplete."))
        }
        guard low.x < high.x, low.y < high.y, low.z < high.z else {
            throw Failure.format(
                String(
                    localized: "cube_lut.error.domain_order",
                    defaultValue: "Domain minimum must be below maximum."))
        }
        id = Self.hash(data)
        title =
            name.flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        self.size = size
        minimum = low
        maximum = high
        values = rows
    }
    static func validID(_ id: String) -> Bool {
        id.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func vector<S: StringProtocol>(_ words: [S]) throws -> SIMD3<Float> {
        guard words.count == 3 else {
            throw Failure.format(
                String(
                    localized: "cube_lut.error.row_format",
                    defaultValue: "Each table row needs three numbers."))
        }
        let numbers = words.compactMap { Float($0) }
        guard numbers.count == 3, numbers.allSatisfy(\.isFinite) else {
            throw Failure.format(
                String(
                    localized: "cube_lut.error.non_finite",
                    defaultValue: "All values must be finite numbers."))
        }
        return SIMD3(numbers[0], numbers[1], numbers[2])
    }
    static func load(id: String, directory: URL) throws -> Self {
        guard validID(id) else { throw Failure.missing }
        let url = directory.appendingPathComponent(id).appendingPathExtension("cube")
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missing }
        let data = try Data(contentsOf: url)
        guard hash(data) == id else {
            throw Failure.format(
                String(
                    localized: "cube_lut.error.file_changed",
                    defaultValue: "The stored file changed."))
        }
        return try Self(data: data, filename: url.lastPathComponent)
    }
}
