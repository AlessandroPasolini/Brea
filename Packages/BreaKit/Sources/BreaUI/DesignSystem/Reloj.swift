import AppKit
import SwiftUI

/// Reloj, the design system, as SwiftUI tokens.
///
/// ## Overview
/// - ``Palette``: fifteen greys, each reproducing the luminance of the same role in Logic Pro.
///   They live in `Resources/Colors.xcassets` (light and dark), so they can be retuned without
///   touching code.
/// - ``Typeface``, ``Space``, ``Radius``, ``Size``, ``Stroke``, ``Knob``: geometry, in points.
///   One point equals one CSS pixel of the reference artifact.
/// - ``Interaction`` and ``Motion``: drag sensitivity and the one animation curve.
/// - Number helpers (positions, formatting, ``ValueParser``) and the shared drag behaviour
///   (``RelojDrag``) live in the extensions below.
///
/// ## Colour rule
/// ``Palette/accent`` marks the value and only the value: numbers, arcs, indices, handles,
/// curves and meter levels. Everything else is grey.
enum Reloj {
    enum Palette {
        private static func named(_ name: String) -> Color { Color(name, bundle: .module) }

        /// The window background and its screens.
        static let surface = named("Surface")
        /// Groups (band panels).
        static let panel = named("Panel")
        /// The display grid.
        static let grid = named("Grid")
        /// Buttons, segmented tracks, selector boxes, menus.
        static let raised = named("Raised")
        /// The knob ring's track and every linear track.
        static let track = named("Track")
        /// Dividers.
        static let line = named("Line")
        /// Knob disc, selected segment, pressed button.
        static let control = named("Control")
        /// Anything that cannot be operated.
        static let disabled = named("Disabled")
        /// The display's 0 dB reference line.
        static let reference = named("Reference")
        /// Scales, quiet labels, unselected options and every mark of a module that is off.
        static let dim = named("Dim")
        /// Parameter labels and button text.
        static let label = named("Label")
        /// Latched button fill, fader cap.
        static let accentFill = named("AccentFill")
        /// Headings, the selected segment, lit icons.
        static let text = named("Text")
        /// The value: see the colour rule above.
        static let accent = named("Accent")
        /// Text and marks drawn on ``accentFill``.
        static let onAccent = named("OnAccent")
    }

    enum Typeface {
        static let label = Font.system(size: 11, weight: .regular)
        static let labelControl = Font.system(size: 11, weight: .medium)
        static let scale = Font.system(size: 11, weight: .regular).monospacedDigit()
        static let valueDense = Font.system(size: 11, weight: .regular).monospacedDigit()
        static let value = Font.system(size: 13, weight: .regular).monospacedDigit()
        static let heading = Font.system(size: 15, weight: .semibold)
    }

    enum Space {
        static let segmentGap: CGFloat = 1
        static let segmentInset: CGFloat = 2
        static let buttonGap: CGFloat = 4
        static let canvasMargin: CGFloat = 10
        static let powerToTitle: CGFloat = 7.7
        static let baselineToRingTangent: CGFloat = 11.6
        static let boxInset: CGFloat = 15.5
        static let labelToValueBaseline: CGFloat = 18.3
        static let panelInset: CGFloat = 19.2
        static let boxTopToLabelBaseline: CGFloat = 23.3
        static let panelGap: CGFloat = 25
        static let headerToContentBaseline: CGFloat = 27.7
        static let panelTopToHeaderBaseline: CGFloat = 31
    }

    /// Corner radii, for `RoundedRectangle(cornerRadius:style: .continuous)`.
    enum Radius {
        static let meter: CGFloat = 2
        static let box: CGFloat = 4.5
        static let control: CGFloat = 5.5
        static let segment: CGFloat = 6
        static let track: CGFloat = 8
        static let panel: CGFloat = 15
    }

    enum Size {
        static let control: CGFloat = 32
        static let controlCompact: CGFloat = 28
        static let segmentedTrack: CGFloat = 36
        static let touch: CGFloat = 44
        static let selectorBox: CGFloat = 58
        static let knobMedium: CGFloat = 57
        /// The display handle's dot and halo diameters.
        static let handle: CGFloat = 12
        static let halo: CGFloat = 18.67
        static let meter: CGFloat = 9
        static let faderThumb = CGSize(width: 27, height: 12)
        static let glyph: CGFloat = 16
        /// The window's content width.
        static let canvasWide: CGFloat = 1170
    }

    enum Stroke {
        static let index: CGFloat = 1.5
        static let ring: CGFloat = 4.88
        static let fader: CGFloat = 4.25
        static let curve: CGFloat = 2
        static let glyph: CGFloat = 1.5
    }

    /// Knob geometry. Angles are in degrees, maths convention (0° at 3 o'clock, counter-clockwise).
    ///
    /// The ring runs from ``ringFrom`` to ``ringTo`` through the bottom gap; the index sweeps
    /// from ``angleMin`` (position 0, lower left) to ``angleMax`` (position 1, lower right).
    /// Bipolar values light the ring from ``bipolarOrigin`` (12 o'clock).
    enum Knob {
        /// Gap between the disc and the ring.
        static let gap: CGFloat = 4.57
        /// The index line, as fractions of the disc radius.
        static let indexFrom: CGFloat = 0.557
        static let indexTo: CGFloat = 1
        static let ringFrom: Double = 235.1
        static let ringTo: Double = 304.9
        static let angleMin: Double = 238
        static let angleMax: Double = 302
        static let bipolarOrigin: Double = 90

        /// The index angle for a 0…1 position.
        static func indexAngle(_ position: Double) -> Double {
            angleMin - position * (angleMin - (angleMax - 360))
        }
    }

    enum Interaction {
        /// Drag distance (points) that sweeps a knob end to end.
        static let dragPerKnobTravel: CGFloat = 180
        /// Drag distance (points) that sweeps a readout end to end.
        static let dragPerValueTravel: CGFloat = 160
        /// Sensitivity while Shift or Option is held.
        static let fineFactor: CGFloat = 0.1
    }

    enum Motion {
        /// The selected segment's slide.
        static let segmentSlide = Animation.timingCurve(0.33, 0.64, 0.67, 0.86, duration: 0.2)
    }

    static let haloOpacity: Double = 0.3

    /// The baseline of one line of `fontSize` text set in a `lineHeight` box (CSS half-leading
    /// model; 0.3555 is the system font's ascent minus half its em box).
    static func baseline(lineHeight: CGFloat, fontSize: CGFloat) -> CGFloat {
        lineHeight / 2 + 0.3555 * fontSize
    }

    /// The baselines of the two common lines: an 11/14 label and a 13/16 value.
    static let labelBaseline = baseline(lineHeight: 14, fontSize: 11)
    static let valueBaseline = baseline(lineHeight: 16, fontSize: 13)

    /// How a control draws its value marks: lit, belonging to a module that is off, or not
    /// operable.
    enum MarkState {
        case on, off, disabled

        init(isOff: Bool, isDisabled: Bool) {
            self = isDisabled ? .disabled : (isOff ? .off : .on)
        }

        var color: Color {
            switch self {
            case .on: Palette.accent
            case .off: Palette.dim
            case .disabled: Palette.disabled
            }
        }
    }
}

// MARK: - Numbers

extension Reloj {
    enum Scale {
        case linear, log
    }

    /// The 0…1 position of `value` in `range`, clamped. Log scales need a positive lower bound.
    static func position(_ value: Double, in range: ClosedRange<Double>, scale: Scale) -> Double {
        let v = min(max(value, range.lowerBound), range.upperBound)
        if scale == .log, range.lowerBound > 0 {
            return log(v / range.lowerBound) / log(range.upperBound / range.lowerBound)
        }
        return (v - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    /// The inverse of ``position(_:in:scale:)``.
    static func value(atPosition position: Double, in range: ClosedRange<Double>, scale: Scale) -> Double {
        let p = min(max(position, 0), 1)
        if scale == .log, range.lowerBound > 0 {
            return range.lowerBound * pow(range.upperBound / range.lowerBound, p)
        }
        return range.lowerBound + p * (range.upperBound - range.lowerBound)
    }

    /// Signed, one decimal. Anything that rounds to zero reads "0.0", never "+0.0" or "-0.0".
    static func formatGain(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == 0 { return "0.0" }
        return (rounded > 0 ? "+" : "-") + String(format: "%.1f", abs(rounded))
    }

    static func formatQ(_ value: Double) -> String { String(format: "%.2f", value) }

    /// Whole hertz ("4000"). Only axes abbreviate to "4k".
    static func formatFrequency(_ value: Double) -> String { String(Int(value.rounded())) }
}

/// Reads a value typed by hand.
///
/// ## Steps
/// 1. Lower-case, turn the minus sign (U+2212) into `-` and drop every space, so "20 000"
///    reads as "20000".
/// 2. Strip one unit suffix: `khz` (×1000), `hz` or `db`.
/// 3. When `allowsKilo` is set, a trailing `k` also multiplies by 1000.
/// 4. Resolve commas: a comma followed by groups of exactly three digits ("20,000"), or any comma
///    in a number that also has a dot, separates thousands; any other comma is the decimal
///    separator ("1,5k", "−2,5").
/// 5. Parse as `Double`; reject non-finite results.
///
/// Accepts, for example, "20k", "20khz", "20KHZ", "20,000", "20 000", "+3 dB" and "0,70".
enum ValueParser {
    static func parse(_ raw: String, allowsKilo: Bool) -> Double? {
        var text = raw.lowercased()
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .filter { !$0.isWhitespace }
        var multiplier = 1.0
        for unit in ["khz", "hz", "db"] where text.hasSuffix(unit) {
            if unit == "khz" { multiplier = 1_000 }
            text.removeLast(unit.count)
            break
        }
        if allowsKilo, text.hasSuffix("k") {
            multiplier = 1_000
            text.removeLast()
        }
        if text.contains(",") {
            if text.contains(".") || text.wholeMatch(of: /[-+]?\d{1,3}(,\d{3})+/) != nil {
                text = text.replacingOccurrences(of: ",", with: "")
            } else {
                text = text.replacingOccurrences(of: ",", with: ".")
            }
        }
        guard let value = Double(text), value.isFinite else { return nil }
        return value * multiplier
    }
}

// MARK: - Interaction

/// Reloj's value drag, shared by knobs and readouts.
///
/// ## Mouse
/// - The whole cell is the target. Moving right or up increases the value (`dx − dy`), so
///   either axis works.
/// - Shift or Option scales the movement by ``Reloj/Interaction/fineFactor``.
/// - Each change of the gesture is applied relative to the previous one, so pressing or
///   releasing a modifier mid-drag never makes the value jump.
/// - Double-click resets, unless `resetsOnDoubleClick` is off (readouts open a text field
///   instead).
///
/// ## Keyboard (when focused)
/// Arrows step 1 % (0.1 % with Shift), Page Up/Down 10 %, Home/End go to the ends and ⌥↩ resets.
///
/// ## Undo
/// `onCommit` fires once per finished gesture or key press, which the editor turns into one
/// undo step.
struct RelojDrag: ViewModifier {
    let position: Double
    let pixelsPerTravel: CGFloat
    let isEnabled: Bool
    let setPosition: (Double) -> Void
    let reset: () -> Void
    var resetsOnDoubleClick = true
    var onCommit: () -> Void = {}

    @State private var dragStart: (position: Double, translation: CGSize)?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        var state = dragStart ?? (position, .zero)
                        let dx = gesture.translation.width - state.translation.width
                        let dy = gesture.translation.height - state.translation.height
                        let flags = NSEvent.modifierFlags
                        let fine = flags.contains(.shift) || flags.contains(.option) ? Reloj.Interaction.fineFactor : 1
                        state.position = min(max(state.position + (dx - dy) / pixelsPerTravel * fine, 0), 1)
                        state.translation = gesture.translation
                        dragStart = state
                        setPosition(state.position)
                    }
                    .onEnded { _ in
                        guard dragStart != nil else { return }
                        dragStart = nil
                        onCommit()
                    },
                isEnabled: isEnabled
            )
            .onTapGesture(count: 2) {
                guard isEnabled, resetsOnDoubleClick else { return }
                reset()
                onCommit()
            }
            .focusable(isEnabled)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard isEnabled else { return .ignored }
        let factor = press.modifiers.contains(.shift) ? 0.1 : 1
        let step: Double
        switch press.key {
        case .upArrow, .rightArrow: step = 0.01
        case .downArrow, .leftArrow: step = -0.01
        case .pageUp: step = 0.1
        case .pageDown: step = -0.1
        case .home: setPosition(0); onCommit(); return .handled
        case .end: setPosition(1); onCommit(); return .handled
        case .return where press.modifiers.contains(.option): reset(); onCommit(); return .handled
        default: return .ignored
        }
        setPosition(min(max(position + step * factor, 0), 1))
        onCommit()
        return .handled
    }
}

extension View {
    func relojDrag(position: Double, pixelsPerTravel: CGFloat, isEnabled: Bool,
                   setPosition: @escaping (Double) -> Void, reset: @escaping () -> Void,
                   resetsOnDoubleClick: Bool = true, onCommit: @escaping () -> Void = {}) -> some View {
        modifier(RelojDrag(position: position, pixelsPerTravel: pixelsPerTravel, isEnabled: isEnabled,
                           setPosition: setPosition, reset: reset, resetsOnDoubleClick: resetsOnDoubleClick,
                           onCommit: onCommit))
    }

    /// Places single-line text so its first baseline sits `y` points below the container's top,
    /// matching the reference's baseline-based layout. Use inside a `ZStack` aligned to the top.
    func placeBaseline(at y: CGFloat) -> some View {
        alignmentGuide(.top) { dimensions in dimensions[.firstTextBaseline] - y }
    }
}

// MARK: - Glyphs

/// Up-down chevrons, drawn on an 8 × 12 grid.
struct RelojChevrons: View {
    let size: CGFloat

    var body: some View {
        let width = size * 0.62, height = size * 0.9
        Canvas { context, canvasSize in
            context.scaleBy(x: canvasSize.width / 8, y: canvasSize.height / 12)
            var path = Path()
            path.move(to: CGPoint(x: 1.2, y: 4.4)); path.addLine(to: CGPoint(x: 4, y: 1.6)); path.addLine(to: CGPoint(x: 6.8, y: 4.4))
            path.move(to: CGPoint(x: 1.2, y: 7.6)); path.addLine(to: CGPoint(x: 4, y: 10.4)); path.addLine(to: CGPoint(x: 6.8, y: 7.6))
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// The power glyph, drawn on a 16 × 16 grid.
///
/// The arc is the reference's SVG arc from (3.98, 3.96) to (12.02, 3.96) with radius 6.25
/// (large arc), so its centre sits on x = 8 below both end points. The stem runs from y 1.4 to 8.2.
struct RelojPowerGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: 8, y: 3.96 + (6.25 * 6.25 - 4.02 * 4.02).squareRoot())
        let startAngle = Angle(radians: atan2(3.96 - centre.y, 3.98 - centre.x))
        let endAngle = Angle(radians: atan2(3.96 - centre.y, 12.02 - centre.x))
        path.addArc(center: centre, radius: 6.25, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        path.move(to: CGPoint(x: 8, y: 1.4))
        path.addLine(to: CGPoint(x: 8, y: 8.2))
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / 16, y: rect.height / 16))
    }
}
