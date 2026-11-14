import SwiftUI
import UIKit

/// Native sliders offer a compact range; numeric entry preserves wider model limits.
struct ParameterControl: View {
    let definition: ParameterDefinition
    let session: EditorSession
    private var isScatterMix: Bool { definition.id == "film_render.halation.scatter_amount" }

    private func choiceTitle(_ raw: String) -> String {
        switch raw {
        case "center_weighted":
            String(localized: "option.metering.center_weighted", defaultValue: "Center Weighted")
        case "matrix": String(localized: "option.metering.matrix", defaultValue: "Matrix")
        case "multi_zone":
            String(localized: "option.metering.multi_zone", defaultValue: "Multi Zone")
        case "partial": String(localized: "option.metering.partial", defaultValue: "Partial")
        case "highlight_weighted":
            String(
                localized: "option.metering.highlight_weighted", defaultValue: "Highlight Weighted")
        case "median": String(localized: "option.metering.median", defaultValue: "Median")
        case "average": String(localized: "option.metering.average", defaultValue: "Average")
        default: raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    var body: some View {
        if definition.defaultFlag != nil {
            AdaptiveToggle(
                definition.title,
                isOn: Binding(
                    get: { session.recipe.flag(definition.id) },
                    set: { value in
                        session.update(key: definition.id) { $0.flags[definition.id] = value }
                    })
            )
            .accessibilityIdentifier(definition.id)
        } else if definition.defaultChoice != nil {
            HStack(spacing: 8) {
                Text(definition.title).foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                Menu {
                    Picker(
                        definition.title,
                        selection: Binding(
                            get: { session.recipe.choice(definition.id) },
                            set: { value in
                                session.update(key: definition.id) { $0.choices[definition.id] = value }
                            }
                        )
                    ) {
                        ForEach(definition.options, id: \.self) {
                            Text(choiceTitle($0)).tag($0)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(choiceTitle(session.recipe.choice(definition.id)))
                            .multilineTextAlignment(.trailing).lineLimit(2)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }.fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.glassProminent).foregroundStyle(.white).tint(Color.accentColor)
                .accessibilityLabel(definition.title)
                .accessibilityValue(choiceTitle(session.recipe.choice(definition.id)))
                .accessibilityIdentifier(definition.id)
            }.font(.caption).frame(minHeight: 44)
        } else {
            NumericControl(
                title: isScatterMix
                    ? String(localized: "control.scatter_mix", defaultValue: "Scatter mix")
                    : definition.title,
                value: Binding(
                    get: {
                        let value = session.recipe.number(definition.id)
                        return isScatterMix ? min(max(value, 0), 1) * 100 : value
                    },
                    set: { value in
                        session.update(key: definition.id) {
                            $0.numbers[definition.id] = isScatterMix ? value / 100 : value
                        }
                    }
                ),
                range: isScatterMix ? 0...100 : definition.sliderRange,
                step: isScatterMix ? 1 : definition.step,
                minimum: definition.minimum, maximum: isScatterMix ? 100 : definition.maximum,
                unit: isScatterMix ? "%" : definition.unit, identifier: definition.id,
                defaultValue: session.recipe.defaultNumber(definition.id)
                    * (isScatterMix ? 100 : 1),
                fillOrigin: isScatterMix || definition.id == "film_render.halation.halation_amount"
                    ? 0 : nil,
                onEditingChanged: { session.setInteraction(key: definition.id, active: $0) })
        }
    }
}

/// Shared range action for print balance and scene tone controls.
struct ControlRangeButton: View {
    let title: String
    let label: String
    let identifier: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .font(.caption)
            .accessibilityLabel(label)
            .accessibilityValue(title)
            .accessibilityIdentifier(identifier)
    }
}

struct NumericControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 0.01
    var minimum: Double?
    var maximum: Double?
    var unit = ""
    var identifier = ""
    var defaultValue = 0.0
    var fillOrigin: Double? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var showEntry = false

    private var effectiveRange: ClosedRange<Double> {
        min(value, range.lowerBound)...max(value, range.upperBound)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                valueButton
            }
            DefaultSlider(
                value: $value, range: effectiveRange, step: step, defaultValue: defaultValue,
                title: title, identifier: identifier, fillOrigin: fillOrigin,
                onEditingChanged: onEditingChanged)
        }
    }
    /// One rounding rule for the label and the editor: what is shown is what is edited.
    private var digits: Int {
        let key = identifier.lowercased()
        return key.contains("exposure") || key.hasSuffix(".pivot") ? 2
            : key.contains("mix") || key.hasSuffix(".temperature") || key.hasSuffix(".warmth")
                || key.hasSuffix(".scatter_amount") ? 0 : 1
    }
    private var displayValue: String {
        value.formatted(.number.precision(.fractionLength(digits)))
            + (unit.isEmpty ? "" : " " + unit)
    }
    private var valueButton: some View {
        Button {
            showEntry = true
        } label: {
            // A quiet capsule says the number is editable without competing with the slider.
            Text(displayValue)
            .monospacedDigit()
            .fixedSize()
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .accessibilityLabel(String(localized: "control.enter", defaultValue: "Enter \(title)"))
        .accessibilityValue(displayValue)
        .accessibilityIdentifier(identifier + ".value")
        .popover(isPresented: $showEntry, arrowEdge: .bottom) {
            NumericEntry(title: title, value: $value, minimum: minimum, maximum: maximum,
                         step: step, digits: digits, unit: unit, defaultValue: defaultValue)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// Native continuous track with one default tick. Reset also has a VoiceOver action.
struct DefaultSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 0.01
    var defaultValue = 0.0
    let title: String
    let identifier: String
    var fillOrigin: Double? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }
    private var bounds: ClosedRange<Double> {
        min(range.lowerBound, defaultValue)...max(range.upperBound, defaultValue)
    }
    private func position(_ number: Double) -> Float {
        Float((number - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound))
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UISlider {
        let slider = PrecisionSlider()
        context.coordinator.slider = slider
        slider.adjustAccessibility = { [weak coordinator = context.coordinator] direction in
            coordinator?.adjustAccessibility(direction)
        }
        slider.addTarget(
            context.coordinator, action: #selector(Coordinator.changed), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.began), for: .touchDown)
        slider.addTarget(
            context.coordinator, action: #selector(Coordinator.ended),
            for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let reset = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.reset))
        reset.numberOfTapsRequired = 2
        reset.cancelsTouchesInView = false
        reset.delaysTouchesEnded = false
        reset.delegate = context.coordinator
        slider.addGestureRecognizer(reset)
        slider.accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: String(
                    localized: "control.reset_to_default", defaultValue: "Reset to Default"),
                target: context.coordinator,
                selector: #selector(Coordinator.accessibleReset))
        ]
        return slider
    }
    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        slider.isEnabled = context.environment.isEnabled
        slider.isUserInteractionEnabled = context.environment.isEnabled
        slider.accessibilityLabel = title
        slider.accessibilityIdentifier = identifier
        slider.tintColor = slider.isEnabled ? UIColor(Color.accentColor) : .tertiaryLabel
        // Keep UIKit and its tick configuration in the same normalized range.
        let configuration = [
            bounds.lowerBound, bounds.upperBound, defaultValue, fillOrigin ?? defaultValue,
        ]
        if context.coordinator.configuration != configuration {
            slider.trackConfiguration = .init(
                allowsTickValuesOnly: false, neutralValue: position(fillOrigin ?? defaultValue),
                ticks: [])
            (slider as? PrecisionSlider)?.defaultTick = position(defaultValue)
            context.coordinator.configuration = configuration
        }
        slider.minimumValue = 0
        slider.maximumValue = 1
        if !slider.isTracking { slider.setValue(position(value), animated: false) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: 32)
    }
    /// UIKit couples configured ticks to magnetic stops. A marker view keeps fine straightening continuous.
    final class PrecisionSlider: UISlider {
        var defaultTick: Float? { didSet { setNeedsLayout() } }
        var adjustAccessibility: ((Int) -> Void)?
        override func accessibilityIncrement() { adjustAccessibility?(1) }
        override func accessibilityDecrement() { adjustAccessibility?(-1) }
        private let marker = UIView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            marker.backgroundColor = .tertiaryLabel
            marker.isUserInteractionEnabled = false
            marker.isAccessibilityElement = false
            addSubview(marker)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            marker.isHidden = defaultTick == nil
            if let value = defaultTick {
                let track = trackRect(forBounds: bounds)
                let thumb = thumbRect(forBounds: bounds, trackRect: track, value: value)
                marker.frame = CGRect(x: thumb.midX - 0.5, y: track.midY - 3, width: 1, height: 6)
            }
        }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: DefaultSlider
        var configuration: [Double] = []
        weak var slider: UISlider?
        private let feedback = UISelectionFeedbackGenerator()
        private var interacting = false
        private var defaultSide = 0
        private func side(of value: Double) -> Int {
            value < parent.defaultValue ? -1 : (value > parent.defaultValue ? 1 : 0)
        }
        init(_ parent: DefaultSlider) { self.parent = parent }
        @objc func began() {
            guard !interacting else { return }
            interacting = true
            defaultSide = side(of: parent.value)
            feedback.prepare()
            parent.onEditingChanged(true)
        }
        @objc func ended() {
            interacting = false
            parent.onEditingChanged(false)
        }
        @objc func changed(_ slider: UISlider) {
            let raw =
                parent.bounds.lowerBound + Double(slider.value)
                * (parent.bounds.upperBound - parent.bounds.lowerBound)
            let newSide = side(of: raw)
            if newSide != 0 && defaultSide != 0 && newSide != defaultSide {
                feedback.selectionChanged()
                feedback.prepare()
            }
            if newSide != 0 { defaultSide = newSide }
            parent.value = min(max(raw, parent.bounds.lowerBound), parent.bounds.upperBound)
        }
        func adjustAccessibility(_ direction: Int) {
            guard slider?.isEnabled == true else { return }
            began()
            parent.value = min(
                max(parent.value + Double(direction) * parent.step, parent.bounds.lowerBound),
                parent.bounds.upperBound)
            slider?.setValue(parent.position(parent.value), animated: false)
            ended()
        }
        @objc func reset() {
            guard slider?.isEnabled == true else { return }
            began()
            parent.value = parent.defaultValue
            slider?.setValue(parent.position(parent.defaultValue), animated: false)
            ended()
            feedback.selectionChanged()
        }
        @objc func accessibleReset() -> Bool {
            reset()
            return true
        }
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
}

/// A compact value editor anchored to the number it edits: the value as shown (same rounding and
/// unit), typed directly or nudged by the slider's own step, with the range and a reset at hand.
private struct NumericEntry: View {
    let title: String
    @Binding var value: Double
    var minimum: Double?
    var maximum: Double?
    let step: Double
    let digits: Int
    let unit: String
    let defaultValue: Double
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private func format(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(digits)).grouping(.never))
    }
    private func clamp(_ number: Double) -> Double {
        min(max(number, minimum ?? -.infinity), maximum ?? .infinity)
    }
    private var parsed: Double? {
        let separator = Locale.current.decimalSeparator ?? "."
        let cleaned = text.replacingOccurrences(of: separator, with: ".").replacingOccurrences(of: "\u{2212}", with: "-")
        guard let number = Double(cleaned), number.isFinite,
              minimum.map({ number >= $0 - 1e-9 }) ?? true, maximum.map({ number <= $0 + 1e-9 }) ?? true
        else { return nil }
        return number
    }
    private func set(_ number: Double) {
        let snapped = clamp((number / step).rounded() * step)
        value = snapped
        text = format(snapped)
    }
    private func commit() {
        guard let parsed else { return }
        value = clamp(parsed)
        dismiss()
    }
    private var rangeText: String? {
        guard let minimum, let maximum else { return nil }
        return format(minimum) + " – " + format(maximum) + (unit.isEmpty ? "" : " " + unit)
    }
    var body: some View {
        VStack(spacing: 12) {
            // Actions on top, so the keyboard below never covers them.
            HStack(spacing: 8) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button(String(localized: "control.reset_to_default", defaultValue: "Reset to Default"),
                       systemImage: "arrow.counterclockwise") { set(defaultValue) }
                    .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                if (minimum ?? -1) < 0 {
                    Button(String(localized: "control.change_sign", defaultValue: "Change Sign"), systemImage: "plusminus") {
                        text = text.hasPrefix("-") ? String(text.dropFirst()) : "-" + text
                    }
                    .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                }
                Button(String(localized: "common.done", defaultValue: "Done"), action: commit)
                    .buttonStyle(.glassProminent).disabled(parsed == nil)
                    .accessibilityIdentifier("numeric.done")
            }
            HStack(spacing: 10) {
                nudge(-1, systemImage: "minus")
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    TextField(title, text: $text)
                        .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                        .multilineTextAlignment(.center).minimumScaleFactor(0.6)
                        .keyboardType(digits == 0 && (minimum ?? 0) >= 0 ? .numberPad : .decimalPad)
                        .focused($isFocused).onSubmit(commit)
                        .accessibilityIdentifier("numeric.input")
                    if !unit.isEmpty {
                        Text(unit).font(.title3.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 120)
                nudge(1, systemImage: "plus")
            }
            if let rangeText {
                Text(verbatim: rangeText).font(.caption).monospacedDigit()
                    .foregroundStyle(parsed == nil ? Color.red : Color.secondary)
            }
        }
        .padding(16)
        .frame(width: 310)
        .onAppear {
            text = format(value)
            isFocused = true
        }
    }
    private func nudge(_ direction: Double, systemImage: String) -> some View {
        Button(systemImage == "plus" ? String(localized: "control.increase", defaultValue: "Increase")
                                     : String(localized: "control.decrease", defaultValue: "Decrease"),
               systemImage: systemImage) {
            set((parsed ?? value) + direction * step)
        }
        .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
        .buttonRepeatBehavior(.enabled)
    }
}

/// Native field layout shared by Adjust and Effects; labels wrap within the proposed width.
struct ParameterFields: View {
    let session: EditorSession
    let prefix: String
    var names: [String]?
    var excluding: [String] = []
    var body: some View {
        ForEach(
            (ParameterDefinition.byGroup[prefix] ?? []).filter {
                (names == nil || names!.contains($0.fieldName)) && !excluding.contains($0.fieldName)
            }
        ) { definition in ParameterControl(definition: definition, session: session) }
    }
}

struct EffectSection: View {
    let title: String
    let prefix: String
    let prominent: [String]
    let session: EditorSession
    var printOnly = false
    var showsDetails = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AdaptiveToggle(
                title,
                isOn: Binding(
                    get: { session.recipe.flag(prefix + ".active") },
                    set: { value in
                        session.update(key: prefix) { $0.flags[prefix + ".active"] = value }
                    })
            )
            .accessibilityIdentifier(prefix + ".active")
            VStack(alignment: .leading, spacing: 12) {
                ParameterFields(session: session, prefix: prefix, names: prominent)
                if showsDetails {
                    EffectDetails(prefix: prefix, prominent: prominent, session: session)
                }
            }.disabled(!session.recipe.flag(prefix + ".active"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(printOnly && session.recipe.bypassesPrint)
    }
}

struct EffectDetails: View {
    let prefix: String
    let prominent: [String]
    let session: EditorSession
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 16) {
                ParameterFields(session: session, prefix: prefix, excluding: ["active"] + prominent)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12).padding(
                .trailing, 8)
        } label: {
            Text(String(localized: "control.details", defaultValue: "Details"))
                .accessibilityIdentifier(prefix + ".details")
        }.disabled(!session.recipe.flag(prefix + ".active"))
    }
}
