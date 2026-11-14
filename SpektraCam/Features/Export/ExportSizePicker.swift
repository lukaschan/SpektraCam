import SwiftUI

/// Export size the way professional editors offer it: the native pixels, a long edge, a
/// percentage, or a paper size at a print resolution. Every choice is resolved against the
/// picture's own native size and never enlarges it.
struct ExportSizePicker: View {
    @Binding var size: PhotoExporter.Size
    /// The edit has a sized paper layout, so a print resolution means something.
    var allowsPrint = false
    private enum Mode: Hashable { case original, longEdge, percent, print }
    private var mode: Mode {
        switch size {
        case .original: .original
        case .longEdge: .longEdge
        case .percent: .percent
        case .print: allowsPrint ? .print : .original
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(String(localized: "export.size", defaultValue: "Size"), selection: Binding(get: { mode }, set: { next in
                switch next {
                case .original: size = .original
                case .longEdge: size = .longEdge(2048)
                case .percent: size = .percent(50)
                case .print: size = .print(ppi: 300)
                }
            })) {
                Text(String(localized: "export.size.original", defaultValue: "Original")).tag(Mode.original)
                Text(String(localized: "export.size.long_edge", defaultValue: "Long edge")).tag(Mode.longEdge)
                Text(String(localized: "export.size.percent", defaultValue: "Percent")).tag(Mode.percent)
                if allowsPrint { Text(String(localized: "export.size.print", defaultValue: "Print")).tag(Mode.print) }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("export.size")
            switch size {
            case .original:
                caption(String(localized: "export.size.original_note",
                               defaultValue: "Every pixel of the crop, film edge and paper. Never enlarged."))
            case .longEdge(let pixels):
                Picker(String(localized: "export.size.long_edge", defaultValue: "Long edge"),
                       selection: Binding(get: { pixels }, set: { size = .longEdge($0) })) {
                    ForEach(PhotoExporter.Size.longEdgePresets, id: \.self) { Text("\($0) px").tag($0) }
                }
                .accessibilityIdentifier("export.size.longEdge")
                caption(String(localized: "export.size.long_edge_note", defaultValue: "Longest side in pixels. Never enlarged."))
            case .percent(let percent):
                Picker(String(localized: "export.size.percent", defaultValue: "Percent"),
                       selection: Binding(get: { percent }, set: { size = .percent($0) })) {
                    ForEach(PhotoExporter.Size.percentPresets, id: \.self) { Text("\($0) %").tag($0) }
                }
                .pickerStyle(.segmented).accessibilityIdentifier("export.size.percent")
            case .print(let ppi):
                Picker(String(localized: "export.size.print", defaultValue: "Print"),
                       selection: Binding(get: { ppi }, set: { size = .print(ppi: $0) })) {
                    ForEach(PhotoExporter.Size.ppiPresets, id: \.self) { Text("\($0) ppi").tag($0) }
                }
                .pickerStyle(.segmented).accessibilityIdentifier("export.size.print")
                caption(String(localized: "export.size.print_note", defaultValue: "The paper size at this resolution. Never enlarged."))
            }
        }
    }
    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
    /// "6000 × 4000 px · 24.0 MP"
    static func describe(width: Int, height: Int) -> String {
        let megapixels = (Double(width) * Double(height) / 1_000_000).formatted(.number.precision(.fractionLength(1)))
        return "\(width) × \(height) px · \(megapixels) MP"
    }
}
