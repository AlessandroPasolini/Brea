import SwiftUI

// MARK: Knob

/// A knob cell: label, value and dial. The whole cell is the drag target (see ``RelojDrag``)
/// and double-clicking the value edits it as text (see ``RelojEditableValue``).
///
/// ## Layout (top to bottom)
/// 1. The label, its baseline at ``Reloj/labelBaseline``.
/// 2. The value, its baseline ``Reloj/Space/labelToValueBaseline`` lower.
/// 3. The dial, its ring tangent ``Reloj/Space/baselineToRingTangent`` below the value baseline.
///
/// The cell is the dial's outer diameter plus 30 pt wide.
struct RelojKnob: View {
    let label: String
    var accessibilityName: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var scale: Reloj.Scale = .linear
    var bipolar = false
    var defaultValue: Double
    let format: (Double) -> String
    var unit: String?
    var isOff = false
    var isDisabled = false
    var onCommit: () -> Void = {}

    private static let outerRadius = Reloj.Size.knobMedium / 2 + Reloj.Knob.gap + Reloj.Stroke.ring
    private static let valueBaseline = Reloj.labelBaseline + Reloj.Space.labelToValueBaseline
    private static let ringTangent = valueBaseline + Reloj.Space.baselineToRingTangent
    private static let width = (2 * outerRadius + 30).rounded()
    private static let height = ringTangent + 2 * outerRadius + 1.5

    private var state: Reloj.MarkState { Reloj.MarkState(isOff: isOff, isDisabled: isDisabled) }
    private var position: Double { Reloj.position(value, in: range, scale: scale) }
    private var valueText: String { unit.map { "\(format(value)) \($0)" } ?? format(value) }

    var body: some View {
        let ringTangent = Self.ringTangent
        ZStack(alignment: .top) {
            Text(label)
                .font(Reloj.Typeface.label)
                .foregroundStyle(isDisabled ? Reloj.Palette.disabled : Reloj.Palette.label)
                .placeBaseline(at: Reloj.labelBaseline)
            RelojEditableValue(text: valueText, editText: format(value), font: Reloj.Typeface.value, color: state.color,
                               isEnabled: !isDisabled, allowsKilo: unit == "Hz") { typed in
                value = min(max(typed, range.lowerBound), range.upperBound)
                onCommit()
            }
            .placeBaseline(at: Self.valueBaseline)
            RelojDial(position: position, bipolar: bipolar, state: state)
                .alignmentGuide(.top) { _ in -ringTangent }
        }
        .frame(width: Self.width, height: Self.height, alignment: .top)
        .relojDrag(position: position, pixelsPerTravel: Reloj.Interaction.dragPerKnobTravel, isEnabled: !isDisabled,
                   setPosition: { value = Reloj.value(atPosition: $0, in: range, scale: scale) },
                   reset: { value = defaultValue }, onCommit: onCommit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName ?? label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.01 : -0.01
            value = Reloj.value(atPosition: position + step, in: range, scale: scale)
        }
    }
}

/// The dial of a knob.
///
/// ## Drawing
/// 1. The disc in `control`.
/// 2. The ring track from ``Reloj/Knob/ringFrom`` to ``Reloj/Knob/ringTo``, round caps.
/// 3. The value arc in the mark colour:
///    - bipolar: from 12 o'clock to the index, butt caps;
///    - unipolar: from the ring's start (a dot continues the track's round cap) to the index.
/// 4. The index line from 0.557 R to R, inset by half its width so its round caps end exactly
///    there.
struct RelojDial: View {
    var position: Double
    var bipolar = false
    var state: Reloj.MarkState = .on

    private static let radius = Reloj.Size.knobMedium / 2
    private static let ringRadius = radius + Reloj.Knob.gap + Reloj.Stroke.ring / 2
    private static let outerRadius = radius + Reloj.Knob.gap + Reloj.Stroke.ring

    var body: some View {
        let radius = Self.radius, ringRadius = Self.ringRadius
        let markColor = state.color
        let position = position, bipolar = bipolar
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let disc = CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)
            context.fill(Path(ellipseIn: disc), with: .color(Reloj.Palette.control))
            context.stroke(Self.arc(centre, ringRadius, from: Reloj.Knob.ringFrom, to: Reloj.Knob.ringTo),
                           with: .color(Reloj.Palette.track),
                           style: StrokeStyle(lineWidth: Reloj.Stroke.ring, lineCap: .round))
            let angle = Reloj.Knob.indexAngle(position)
            if bipolar {
                let origin = Reloj.Knob.bipolarOrigin
                if abs(angle - origin) > 0.05 {
                    let (from, to) = angle < origin ? (origin, angle) : (angle, origin)
                    context.stroke(Self.arc(centre, ringRadius, from: from, to: to), with: .color(markColor),
                                   style: StrokeStyle(lineWidth: Reloj.Stroke.ring, lineCap: .butt))
                }
            } else if position > 0.0005 {
                let start = Self.point(centre, ringRadius, Reloj.Knob.ringFrom)
                let cap = Reloj.Stroke.ring / 2
                context.fill(Path(ellipseIn: CGRect(x: start.x - cap, y: start.y - cap, width: cap * 2, height: cap * 2)),
                             with: .color(markColor))
                if angle < Reloj.Knob.ringFrom {
                    context.stroke(Self.arc(centre, ringRadius, from: Reloj.Knob.ringFrom, to: angle), with: .color(markColor),
                                   style: StrokeStyle(lineWidth: Reloj.Stroke.ring, lineCap: .butt))
                }
            }
            let width = Reloj.Stroke.index
            var index = Path()
            index.move(to: Self.point(centre, Reloj.Knob.indexFrom * radius + width / 2, angle))
            index.addLine(to: Self.point(centre, Reloj.Knob.indexTo * radius - width / 2, angle))
            context.stroke(index, with: .color(markColor), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        .frame(width: Self.outerRadius * 2, height: Self.outerRadius * 2)
        .accessibilityHidden(true)
    }

    private static func point(_ centre: CGPoint, _ radius: CGFloat, _ degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: centre.x + radius * CGFloat(cos(radians)), y: centre.y - radius * CGFloat(sin(radians)))
    }

    /// An arc drawn clockwise on screen from `from` to `to` (maths-convention degrees). With y
    /// pointing down, a maths angle θ is the screen angle −θ.
    private static func arc(_ centre: CGPoint, _ radius: CGFloat, from: Double, to: Double) -> Path {
        var sweep = from - to
        while sweep < 0 { sweep += 360 }
        var path = Path()
        path.addArc(center: centre, radius: radius,
                    startAngle: .degrees(-from), endAngle: .degrees(-from + sweep), clockwise: false)
        return path
    }
}

// MARK: Readout

/// A label over a draggable, editable value, centred.
///
/// The value's hit target extends 8 pt beyond its text, so a near miss drags the value instead
/// of the panel behind it. Double-click opens the text field rather than resetting.
struct RelojReadout: View {
    enum Size { case dense, regular }

    let label: String
    var accessibilityName: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var scale: Reloj.Scale = .linear
    var defaultValue: Double
    let format: (Double) -> String
    var unit: String?
    var size: Size = .regular
    var width: CGFloat
    var isOff = false
    var isDisabled = false
    var onCommit: () -> Void = {}

    private var position: Double { Reloj.position(value, in: range, scale: scale) }
    private var valueText: String { unit.map { "\(format(value)) \($0)" } ?? format(value) }

    /// The gap between the label's 14 pt line box and the value's, so the baselines sit
    /// ``Reloj/Space/labelToValueBaseline`` apart.
    private var valueTopMargin: CGFloat {
        let valueLine: CGFloat = size == .dense ? Reloj.labelBaseline : Reloj.valueBaseline
        return Reloj.Space.labelToValueBaseline - (14 - Reloj.labelBaseline) - valueLine
    }

    var body: some View {
        let state = Reloj.MarkState(isOff: isOff, isDisabled: isDisabled)
        VStack(spacing: 0) {
            Text(label)
                .font(Reloj.Typeface.label)
                .foregroundStyle(isDisabled ? Reloj.Palette.disabled : Reloj.Palette.label)
                .frame(height: 14)
            RelojEditableValue(text: valueText, editText: format(value),
                               font: size == .dense ? Reloj.Typeface.valueDense : Reloj.Typeface.value, color: state.color,
                               isEnabled: !isDisabled, allowsKilo: unit == "Hz") { typed in
                value = min(max(typed, range.lowerBound), range.upperBound)
                onCommit()
            }
            .frame(height: size == .dense ? 14 : 16)
            .padding(.top, valueTopMargin)
            .contentShape(Rectangle().inset(by: -8))
            .relojDrag(position: position, pixelsPerTravel: Reloj.Interaction.dragPerValueTravel, isEnabled: !isDisabled,
                       setPosition: { value = Reloj.value(atPosition: $0, in: range, scale: scale) },
                       reset: { value = defaultValue }, resetsOnDoubleClick: false, onCommit: onCommit)
        }
        .frame(width: width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName ?? label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.01 : -0.01
            value = Reloj.value(atPosition: position + step, in: range, scale: scale)
        }
    }
}

// MARK: Editable value

/// A value that becomes a text field on double-click.
///
/// ## Editing
/// 1. Double-click: the field opens with the number alone (`editText`, no unit), focused.
/// 2. Return, or focus moving elsewhere (a click on empty space resigns it), applies the text
///    through ``ValueParser``. Text that does not parse leaves the value unchanged.
/// 3. Escape closes the field without applying.
///
/// The standard Edit menu commands (Cut, Copy, Paste, Select All) work inside the field.
struct RelojEditableValue: View {
    let text: String
    let editText: String
    let font: Font
    let color: Color
    let isEnabled: Bool
    let allowsKilo: Bool
    let commit: (Double) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(Reloj.Palette.text)
                .multilineTextAlignment(.center)
                .frame(width: 72)
                .padding(.vertical, 1)
                .background(Reloj.Palette.raised, in: RoundedRectangle(cornerRadius: Reloj.Radius.box, style: .continuous))
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onSubmit { finish(applying: true) }
                .onExitCommand { finish(applying: false) }
                .onChange(of: isFocused) { _, focused in
                    if !focused { finish(applying: true) }
                }
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard isEnabled else { return }
                    draft = editText
                    isEditing = true
                }
        }
    }

    private func finish(applying: Bool) {
        guard isEditing else { return }
        isEditing = false
        if applying, let value = ValueParser.parse(draft, allowsKilo: allowsKilo) { commit(value) }
    }
}

// MARK: Selector

/// One choice of a selector or segmented control.
struct RelojOption<Value: Hashable & Sendable>: Identifiable, Sendable {
    let value: Value
    let label: String
    var id: Value { value }
}

/// An inline selector: the value and chevrons open a menu. Its hit target extends 8 pt beyond
/// the text, so a near miss opens the menu instead of grabbing the panel.
struct RelojSelector<Value: Hashable & Sendable>: View {
    let accessibilityName: String
    let options: [RelojOption<Value>]
    @Binding var selection: Value
    var isOff = false
    var isDisabled = false
    var onCommit: () -> Void = {}

    var body: some View {
        let current = options.first { $0.value == selection } ?? options[0]
        Menu {
            Picker(accessibilityName, selection: Binding(get: { selection }, set: { selection = $0; onCommit() })) {
                ForEach(options) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(current.label)
                    .font(Reloj.Typeface.value)
                    .multilineTextAlignment(.center)
                RelojChevrons(size: 13)
            }
            .foregroundStyle(Reloj.MarkState(isOff: isOff, isDisabled: isDisabled).color)
            .contentShape(Rectangle().inset(by: -8))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(isDisabled)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("\(accessibilityName): \(current.label)")
    }
}

/// A boxed selector for the processor's main mode: a dim label over a heading-size value, in a
/// raised box.
struct RelojBoxedSelector: View {
    let label: String
    let options: [String]
    @Binding var selection: String
    var width: CGFloat = 148

    var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Reloj.Radius.box, style: .continuous)
                    .fill(Reloj.Palette.raised)
                Text(label)
                    .font(Reloj.Typeface.label)
                    .foregroundStyle(Reloj.Palette.dim)
                    .placeBaseline(at: Reloj.Space.boxTopToLabelBaseline)
                    .padding(.leading, Reloj.Space.boxInset)
                HStack(spacing: 6) {
                    Text(selection)
                        .font(Reloj.Typeface.heading)
                    RelojChevrons(size: 15)
                }
                .foregroundStyle(Reloj.Palette.accent)
                .placeBaseline(at: Reloj.Space.boxTopToLabelBaseline + Reloj.Space.labelToValueBaseline)
                .padding(.leading, Reloj.Space.boxInset)
            }
            .frame(width: width, height: Reloj.Size.selectorBox)
            .contentShape(RoundedRectangle(cornerRadius: Reloj.Radius.box, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(label): \(selection)")
    }
}

// MARK: Segmented

/// Equal segments in a raised track. A single selection fill is matched across segments, so it
/// slides to the new one (``Reloj/Motion/segmentSlide``) instead of two fills cross-fading.
/// Reduce Motion switches without animation.
struct RelojSegmented<Value: Hashable & Sendable>: View {
    let accessibilityName: String
    let options: [RelojOption<Value>]
    @Binding var selection: Value
    var width: CGFloat

    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Reloj.Space.segmentGap) {
            ForEach(options) { option in
                let isSelected = option.value == selection
                Text(option.label)
                    .font(Reloj.Typeface.labelControl)
                    .foregroundStyle(isSelected ? Reloj.Palette.text : Reloj.Palette.dim)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: Reloj.Size.control)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: Reloj.Radius.segment, style: .continuous)
                                .fill(Reloj.Palette.control)
                                .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(reduceMotion ? nil : Reloj.Motion.segmentSlide) { selection = option.value }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(option.label)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            }
        }
        .padding(Reloj.Space.segmentInset)
        .frame(width: width, height: Reloj.Size.segmentedTrack)
        .background(RoundedRectangle(cornerRadius: Reloj.Radius.track, style: .continuous).fill(Reloj.Palette.raised))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
    }
}

// MARK: Button

/// Reloj's button.
///
/// | State | Fill | Text |
/// |---|---|---|
/// | Normal | `raised` | `label` |
/// | Pressed | `control` | `label` |
/// | Latched (toggle on) | `accentFill` | `onAccent` |
/// | Disabled | unchanged | `disabled` |
struct RelojButtonStyle: ButtonStyle {
    var isSelected = false
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, isSelected: isSelected, width: width)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let width: CGFloat?
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let background = isSelected ? Reloj.Palette.accentFill
                : (configuration.isPressed && isEnabled ? Reloj.Palette.control : Reloj.Palette.raised)
            let foreground = !isEnabled ? Reloj.Palette.disabled : (isSelected ? Reloj.Palette.onAccent : Reloj.Palette.label)
            configuration.label
                .font(Reloj.Typeface.labelControl)
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .frame(minWidth: Reloj.Size.touch)
                .frame(width: width, height: Reloj.Size.control)
                .background(background, in: RoundedRectangle(cornerRadius: Reloj.Radius.control, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Reloj.Radius.control, style: .continuous))
        }
    }
}

struct RelojButton: View {
    let title: String
    var width: CGFloat?
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(RelojButtonStyle(width: width))
    }
}

/// A latching button, filled with `accentFill` while on.
struct RelojToggleButton: View {
    let title: String
    @Binding var isOn: Bool
    var width: CGFloat?

    var body: some View {
        Button(title) { isOn.toggle() }
            .buttonStyle(RelojButtonStyle(isSelected: isOn, width: width))
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: Power

/// A module's power switch: the glyph in `text` while on, `dim` while off.
struct RelojPower: View {
    let accessibilityName: String
    @Binding var isOn: Bool
    var isDisabled = false
    var onCommit: () -> Void = {}

    var body: some View {
        Button {
            isOn.toggle()
            onCommit()
        } label: {
            RelojPowerGlyph()
                .stroke(style: StrokeStyle(lineWidth: Reloj.Stroke.glyph, lineCap: .round))
                .frame(width: Reloj.Size.glyph, height: Reloj.Size.glyph)
                .foregroundStyle(isDisabled ? Reloj.Palette.disabled : (isOn ? Reloj.Palette.text : Reloj.Palette.dim))
                .frame(width: Reloj.Size.controlCompact, height: Reloj.Size.controlCompact)
                .contentShape(RoundedRectangle(cornerRadius: Reloj.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: Fader

/// A vertical fader.
///
/// ## Drawing
/// 1. The track, full height.
/// 2. When bipolar, the value fill from the centre to the cap.
/// 3. Five ticks to the right of the track, at 0, 25, 50, 75 and 100 %.
/// 4. The pill cap (`accentFill`, or `control` when disabled) with a centre line.
///
/// ## Interaction
/// Absolute, as on a physical fader: the pointer's height on the track is the value. A
/// double-click resets; `onCommit` fires once per gesture.
struct RelojFader: View {
    let accessibilityName: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var bipolar = false
    var defaultValue: Double
    let valueText: String
    var height: CGFloat = 306
    var isDisabled = false
    var onCommit: () -> Void = {}

    private static let ticks: [Double] = [0, 0.25, 0.5, 0.75, 1]
    private static let tickOffset: CGFloat = 11
    private static let tickLength: CGFloat = 9
    private static let width = 2 * (tickOffset + tickLength)

    @State private var isDragging = false

    var body: some View {
        let thumb = Reloj.Size.faderThumb
        let travel = height - thumb.height
        let position = Reloj.position(value, in: range, scale: .linear)
        let state: Reloj.MarkState = isDisabled ? .disabled : .on
        let bipolar = bipolar
        Canvas { context, size in
            let midX = size.width / 2
            let y = { (p: Double) -> CGFloat in thumb.height / 2 + (1 - p) * travel }
            context.fill(Path(CGRect(x: midX - Reloj.Stroke.fader / 2, y: 0, width: Reloj.Stroke.fader, height: size.height)),
                         with: .color(Reloj.Palette.track))
            if bipolar {
                let top = min(y(position), y(0.5))
                context.fill(Path(CGRect(x: midX - Reloj.Stroke.fader / 2, y: top, width: Reloj.Stroke.fader,
                                         height: abs(y(position) - y(0.5)))), with: .color(state.color))
            }
            for tick in Self.ticks {
                context.fill(Path(CGRect(x: midX + Self.tickOffset, y: y(tick) - 0.5, width: Self.tickLength, height: 1)),
                             with: .color(Reloj.Palette.dim))
            }
            let cap = CGRect(x: midX - thumb.width / 2, y: y(position) - thumb.height / 2, width: thumb.width, height: thumb.height)
            context.fill(Path(roundedRect: cap, cornerRadius: thumb.height / 2),
                         with: .color(state == .on ? Reloj.Palette.accentFill : Reloj.Palette.control))
            context.fill(Path(CGRect(x: midX - 4, y: y(position) - 0.75, width: 8, height: 1.5)),
                         with: .color(state == .on ? Reloj.Palette.onAccent : state.color))
        }
        .frame(width: Self.width, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    guard !isDisabled else { return }
                    isDragging = true
                    let p = 1 - (gesture.location.y - thumb.height / 2) / travel
                    value = Reloj.value(atPosition: p, in: range, scale: .linear)
                }
                .onEnded { _ in
                    guard isDragging else { return }
                    isDragging = false
                    onCommit()
                }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard !isDisabled else { return }
            value = defaultValue
            onCommit()
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            value = Reloj.value(atPosition: position + (direction == .increment ? 0.01 : -0.01), in: range, scale: .linear)
        }
    }
}

// MARK: Meter

/// A horizontal level bar with a peak line and, optionally, a scale of marks below it.
/// `level` and `peak` are 0…1 positions along the bar.
struct RelojMeter: View {
    struct Mark: Hashable {
        let position: Double
        let label: String
    }

    let accessibilityName: String
    let level: Double
    let peak: Double?
    let valueText: String
    var width: CGFloat = 167
    var marks: [Mark] = []

    var body: some View {
        let thickness = Reloj.Size.meter
        let tickTop = thickness + 6.7
        let labelBaseline = thickness + 24.8
        let height = marks.isEmpty ? thickness : labelBaseline + 3.5
        let width = width, level = level, peak = peak, marks = marks
        Canvas { context, _ in
            let radius = min(Reloj.Radius.meter, thickness / 2)
            context.translateBy(x: 10, y: 0)
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: thickness), cornerRadius: radius),
                         with: .color(Reloj.Palette.track))
            let clamped = min(max(level, 0), 1)
            if clamped > 0 {
                context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: clamped * width, height: thickness), cornerRadius: radius),
                             with: .color(Reloj.Palette.accent))
            }
            if let peak {
                context.fill(Path(CGRect(x: min(max(peak, 0), 1) * width - 0.75, y: 0, width: 1.5, height: thickness)),
                             with: .color(Reloj.Palette.accent))
            }
            for mark in marks {
                let x = mark.position * width
                context.fill(Path(CGRect(x: x - 0.5, y: tickTop, width: 1, height: 4)), with: .color(Reloj.Palette.dim))
                var text = context.resolve(Text(mark.label).font(Reloj.Typeface.scale))
                text.shading = .color(Reloj.Palette.dim)
                context.draw(text, at: CGPoint(x: x, y: labelBaseline), anchor: UnitPoint(x: 0.5, y: Self.baselineAnchor(text)))
            }
        }
        .frame(width: width + 20, height: height)
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(valueText)
    }

    /// The unit anchor that puts a resolved single-line text's baseline on the drawing point.
    static func baselineAnchor(_ text: GraphicsContext.ResolvedText) -> CGFloat {
        let size = text.measure(in: CGSize(width: 400, height: 100))
        return size.height > 0 ? text.firstBaseline(in: size) / size.height : 1
    }
}

// MARK: Panel and divider

/// A large group: `panel` fill, 15 pt corners, a power + heading header and the content.
///
/// ## Layout
/// - The header's baseline sits ``Reloj/Space/panelTopToHeaderBaseline`` below the top. With a
///   power button the header row shifts 4 pt up and 6 pt left, as in the reference.
/// - The content's first label baseline sits ``Reloj/Space/headerToContentBaseline`` below the
///   header's, inset ``Reloj/Space/panelInset`` on both sides.
struct RelojPanel<Content: View>: View {
    let title: String
    @Binding var isOn: Bool
    var isDisabled = false
    var width: CGFloat
    var height: CGFloat
    var onToggle: () -> Void = {}
    @ViewBuilder var content: () -> Content

    private static var headerTop: CGFloat {
        Reloj.Space.panelTopToHeaderBaseline - Reloj.baseline(lineHeight: 20, fontSize: 15) - 4
    }
    private static var contentTop: CGFloat {
        Reloj.Space.panelTopToHeaderBaseline + Reloj.Space.headerToContentBaseline - Reloj.labelBaseline
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Reloj.Radius.panel, style: .continuous)
                .fill(Reloj.Palette.panel)
            HStack(spacing: Reloj.Space.powerToTitle) {
                RelojPower(accessibilityName: "\(title): on", isOn: $isOn, isDisabled: isDisabled, onCommit: onToggle)
                Text(title)
                    .font(Reloj.Typeface.heading)
                    .foregroundStyle(isDisabled ? Reloj.Palette.disabled : (isOn ? Reloj.Palette.text : Reloj.Palette.dim))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            .frame(height: Reloj.Size.controlCompact)
            .padding(.top, Self.headerTop)
            .padding(.leading, Reloj.Space.panelInset - 6)
            content()
                .padding(.top, Self.contentTop)
                .padding(.horizontal, Reloj.Space.panelInset)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A 1 pt vertical rule in `line`.
struct RelojDivider: View {
    let length: CGFloat

    var body: some View {
        Rectangle()
            .fill(Reloj.Palette.line)
            .frame(width: 1, height: length)
            .accessibilityHidden(true)
    }
}
