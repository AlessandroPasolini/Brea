import BreaDSP
import SwiftUI

/// The mapping between the display's plot and its units: frequency on a log axis from 20 Hz to
/// 20 kHz, gain on a linear axis. The plot is `width − 30` points wide (the gain scale sits to
/// its right) and `height` points tall.
struct DisplayScale {
    static let minFrequency = 20.0
    static let maxFrequency = 20_000.0

    let plotWidth: CGFloat
    let height: CGFloat
    let gainRange: ClosedRange<Double>

    func x(_ frequency: Double) -> CGFloat {
        log(frequency / Self.minFrequency) / log(Self.maxFrequency / Self.minFrequency) * plotWidth
    }

    func frequency(atX x: CGFloat) -> Double {
        Self.minFrequency * pow(Self.maxFrequency / Self.minFrequency, Double(min(max(x / plotWidth, 0), 1)))
    }

    func y(_ gain: Double) -> CGFloat {
        (gainRange.upperBound - gain) / (gainRange.upperBound - gainRange.lowerBound) * height
    }

    func gain(atY y: CGFloat) -> Double {
        min(max(gainRange.upperBound - Double(y / height) * (gainRange.upperBound - gainRange.lowerBound), gainRange.lowerBound),
            gainRange.upperBound)
    }
}

/// Reloj's Display: the equalizer's response and its handles.
///
/// ## Layers (back to front)
/// 1. Grid, 0 dB reference and scales.
/// 2. The analyzer spectrum (``SpectrumLayer``), the only layer redrawn at display rate.
/// 3. The summed response in `dim`; the revealed band's own response in `accent`, with its
///    glow (a gradient fill down to its 0 dB line and a soft light under the line, see
///    `drawGlow`), its handle, and a halo while the pointer is on the handle or dragging it.
///    Nothing glows while no band is revealed.
///
/// ## Revealing and grabbing
/// 1. Hovering finds the nearest enabled band, in octaves, within its bandwidth (at least
///    10 pt); that band is revealed and reported through `onHoverChange`.
/// 2. Its handle can be grabbed within the 28 pt target. A drag sets frequency and gain from the
///    pointer, calls `onSelect` once (to bring its panel into view) and `onCommit` at the end.
/// 3. Without hovering, the band whose panel is hovered (`highlighted`) is revealed.
///
/// The pre-amp arrives as `offset`: it shifts the drawing, never the bands' values.
struct EqualizerDisplay: View {
    let label: String
    let width: CGFloat
    /// Plot height; the view adds 26 pt below for the frequency labels.
    let height: CGFloat
    let gainRange: ClosedRange<Double>
    let gainStep: Double
    /// Enabled bands only.
    let bands: [EQBand]
    let offset: Double
    let sampleRate: Double
    let highlighted: EQBand.ID?
    let isDisabled: Bool
    let monitor: SignalMonitor
    var onHoverChange: (EQBand.ID?) -> Void = { _ in }
    let onSelect: (EQBand.ID) -> Void
    let onHandleChange: (EQBand.ID, _ frequency: Double, _ gain: Double) -> Void
    let onCommit: () -> Void

    @State private var dragging: EQBand.ID?
    @State private var hovered: EQBand.ID?
    @State private var near: EQBand.ID?

    /// The reference draws outside its box (the top "+12" label, handles at the edges), so every
    /// canvas gets this margin, which the layout does not see.
    private static let overdraw: CGFloat = 12
    private static let gridFrequencies: [Double] = [30, 40, 50, 60, 70, 80, 90, 100, 200, 300, 400, 500, 600, 700, 800, 900,
                                                    1_000, 2_000, 3_000, 4_000, 5_000, 6_000, 7_000, 8_000, 9_000, 10_000]
    private static let frequencyLabels: [(Double, String)] = [(20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"),
                                                              (1_000, "1k"), (2_000, "2k"), (5_000, "5k"), (10_000, "10k"), (20_000, "20k")]

    private var scale: DisplayScale { DisplayScale(plotWidth: width - 30, height: height, gainRange: gainRange) }
    private var quietInk: Color { isDisabled ? Reloj.Palette.disabled : Reloj.Palette.dim }

    private func shiftedY(_ gain: Double) -> CGFloat {
        scale.y(min(max(gain + offset, gainRange.lowerBound), gainRange.upperBound))
    }

    /// Pass and notch filters have no gain: their handle sits on the 0 dB line.
    private func handleGain(_ band: EQBand) -> Double { band.type.usesGain ? band.gainDB : 0 }

    private var revealedID: EQBand.ID? {
        guard !isDisabled else { return nil }
        return dragging ?? hovered ?? highlighted
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            layer { context in drawGrid(in: &context) }
            SpectrumLayer(monitor: monitor, scale: scale, sampleRate: sampleRate, color: quietInk)
            layer { context in drawCurves(in: &context) }
        }
        .frame(width: width, height: height + 26, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard dragging == nil else { return }
            switch phase {
            case .active(let location): updateHover(at: location)
            case .ended: hovered = nil; near = nil; onHoverChange(nil)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    guard !isDisabled else { return }
                    if dragging == nil {
                        updateHover(at: gesture.startLocation)
                        guard let id = near else { return }
                        dragging = id
                        onSelect(id)
                    }
                    guard let id = dragging else { return }
                    onHandleChange(id, scale.frequency(atX: gesture.location.x), scale.gain(atY: gesture.location.y) - offset)
                }
                .onEnded { gesture in
                    guard dragging != nil else { return }
                    dragging = nil
                    updateHover(at: gesture.location)
                    onCommit()
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(bands.count) bands")
    }

    /// A canvas covering the view plus the overdraw margin, with the plot's origin at (0, 0).
    private func layer(_ draw: @escaping (inout GraphicsContext) -> Void) -> some View {
        let overdraw = Self.overdraw
        return Canvas { context, _ in
            context.translateBy(x: overdraw, y: overdraw)
            draw(&context)
        }
        .frame(width: width + 2 * overdraw, height: height + 26 + 2 * overdraw)
        .padding(-overdraw)
        .allowsHitTesting(false)
    }

    private func updateHover(at location: CGPoint) {
        let scale = scale
        let pointerOctave = log2(scale.frequency(atX: location.x))
        let minimumOctaves = 10 / (scale.plotWidth / log2(DisplayScale.maxFrequency / DisplayScale.minFrequency))
        var best: EQBand?
        var bestDistance = Double.infinity
        for band in bands {
            let distance = abs(pointerOctave - log2(band.frequency))
            let reach = max(asinh(1 / (2 * band.q)) / M_LN2, minimumOctaves)
            if distance <= reach, distance < bestDistance {
                bestDistance = distance
                best = band
            }
        }
        hovered = best?.id
        onHoverChange(best?.id)
        if let best {
            let distance = hypot(location.x - scale.x(best.frequency), location.y - shiftedY(handleGain(best)))
            near = distance <= Reloj.Size.controlCompact / 2 ? best.id : nil
        } else {
            near = nil
        }
    }

    // MARK: Drawing

    private func drawGrid(in context: inout GraphicsContext) {
        let scale = scale
        let reference = isDisabled ? Reloj.Palette.disabled : Reloj.Palette.reference
        let zeroY = scale.y(0)

        for f in Self.gridFrequencies {
            context.fill(Path(CGRect(x: scale.x(f) - 0.5, y: 0, width: 1, height: height)), with: .color(Reloj.Palette.grid))
        }
        let gains = Array(stride(from: (gainRange.lowerBound / gainStep).rounded(.up) * gainStep,
                                 through: gainRange.upperBound + 1e-9, by: gainStep))
        for g in gains where g != 0 {
            context.fill(Path(CGRect(x: 0, y: scale.y(g) - 0.5, width: scale.plotWidth, height: 1)), with: .color(Reloj.Palette.grid))
        }
        context.fill(Path(CGRect(x: 0, y: zeroY - 0.5, width: scale.plotWidth, height: 1)), with: .color(reference))

        for g in gains {
            drawScale(g > 0 ? "+\(Int(g))" : "\(Int(g))", in: &context, at: CGPoint(x: scale.plotWidth + 22.6, y: scale.y(g) + 3.9),
                      anchorX: 1)
        }
        for (f, text) in Self.frequencyLabels {
            drawScale(text, in: &context, at: CGPoint(x: min(max(scale.x(f), 8), scale.plotWidth - 8), y: zeroY + 19.3),
                      anchorX: 0.5)
        }
    }

    private func drawCurves(in context: inout GraphicsContext) {
        let markColor = (isDisabled ? Reloj.MarkState.disabled : .on).color
        let style = StrokeStyle(lineWidth: Reloj.Stroke.curve, lineJoin: .round)

        let sum = EQResponse(bands: bands, sampleRate: sampleRate)
        context.stroke(curve { sum.decibels(at: $0) }, with: .color(quietInk), style: style)

        guard let id = revealedID, let band = bands.first(where: { $0.id == id }) else { return }
        let single = EQResponse(bands: [band], sampleRate: sampleRate)
        let bandCurve = curve { single.decibels(at: $0) }
        drawGlow(of: bandCurve, color: markColor, in: &context)
        context.stroke(bandCurve, with: .color(markColor), style: style)
        let centre = CGPoint(x: scale.x(band.frequency), y: shiftedY(handleGain(band)))
        if dragging == id || near == id {
            let halo = Reloj.Size.halo / 2
            context.fill(Path(ellipseIn: CGRect(x: centre.x - halo, y: centre.y - halo, width: 2 * halo, height: 2 * halo)),
                         with: .color(markColor.opacity(Reloj.haloOpacity)))
        }
        let dot = Reloj.Size.handle / 2
        context.fill(Path(ellipseIn: CGRect(x: centre.x - dot, y: centre.y - dot, width: 2 * dot, height: 2 * dot)),
                     with: .color(markColor))
    }

    /// The revealed band's glow, in its own colour:
    /// 1. The area between its curve and its 0 dB line (shifted by the pre-amp) is filled with
    ///    a gradient: strongest at the curve's furthest point, clear at the line. Boosts and
    ///    cuts each fade towards the line.
    /// 2. A blurred copy of the curve under the line itself.
    ///
    /// Both stay inside the area between the curve and the 0 dB line: a cut glows upwards, a
    /// boost downwards, and nothing spills past the curve.
    private func drawGlow(of bandCurve: Path, color: Color, in context: inout GraphicsContext) {
        let baseline = shiftedY(0)
        let bounds = bandCurve.boundingRect
        var area = bandCurve
        area.addLine(to: CGPoint(x: scale.plotWidth, y: baseline))
        area.addLine(to: CGPoint(x: 0, y: baseline))
        area.closeSubpath()

        let strong = color.opacity(Self.glowFillOpacity), clear = color.opacity(0)
        var fill = context
        fill.clip(to: area)
        if bounds.minY < baseline {
            fill.fill(Path(CGRect(x: 0, y: bounds.minY, width: scale.plotWidth, height: baseline - bounds.minY)),
                      with: .linearGradient(Gradient(colors: [strong, clear]),
                                            startPoint: CGPoint(x: 0, y: bounds.minY), endPoint: CGPoint(x: 0, y: baseline)))
        }
        if bounds.maxY > baseline {
            fill.fill(Path(CGRect(x: 0, y: baseline, width: scale.plotWidth, height: bounds.maxY - baseline)),
                      with: .linearGradient(Gradient(colors: [clear, strong]),
                                            startPoint: CGPoint(x: 0, y: baseline), endPoint: CGPoint(x: 0, y: bounds.maxY)))
        }

        // Clipped like the fill, so the light only spreads towards the 0 dB line, never outwards.
        var halo = fill
        halo.addFilter(.blur(radius: Self.glowBlurRadius))
        halo.stroke(bandCurve, with: .color(color.opacity(Self.glowLineOpacity)),
                    style: StrokeStyle(lineWidth: Reloj.Stroke.curve * 3, lineJoin: .round))
    }

    private static let glowFillOpacity = 0.35
    private static let glowLineOpacity = 0.7
    private static let glowBlurRadius: CGFloat = 4

    /// A response sampled every 2 pt across the plot, shifted by the offset and clamped.
    private func curve(_ response: (Double) -> Double) -> Path {
        let scale = scale
        var path = Path()
        var px: CGFloat = 0
        path.move(to: CGPoint(x: 0, y: shiftedY(response(scale.frequency(atX: 0)))))
        while px < scale.plotWidth {
            px = min(px + 2, scale.plotWidth)
            path.addLine(to: CGPoint(x: px, y: shiftedY(response(scale.frequency(atX: px)))))
        }
        return path
    }

    private func drawScale(_ string: String, in context: inout GraphicsContext, at point: CGPoint, anchorX: CGFloat) {
        var text = context.resolve(Text(string).font(Reloj.Typeface.scale))
        text.shading = .color(quietInk)
        context.draw(text, at: point, anchor: UnitPoint(x: anchorX, y: RelojMeter.baselineAnchor(text)))
    }
}

/// The analyzer as a thin, quiet line: 0 dBFS at the top of the plot, −90 dBFS at the bottom.
///
/// It is the only part of the display that reads ``SignalMonitor/spectrum``, so the display rate
/// redraw stays confined to this layer.
///
/// - **Curve.** The points pass through a uniform Catmull-Rom spline, drawn as cubic Béziers
///   (for the segment P1→P2: controls P1 + (P2 − P0)/6 and P2 − (P3 − P1)/6). The line goes
///   through every analysed point with a continuous slope, without the corners of a polyline.
/// - **Rendering.** `drawingGroup()` rasterizes the layer offscreen with Metal and composites
///   the result, so the per-frame path stroke never reaches the CPU renderer.
private struct SpectrumLayer: View {
    let monitor: SignalMonitor
    let scale: DisplayScale
    let sampleRate: Double
    let color: Color

    var body: some View {
        Canvas { context, _ in
            guard let spectrum = monitor.spectrum, spectrum.count > 2 else { return }
            let top = min(DisplayScale.maxFrequency, sampleRate / 2)
            let last = Double(spectrum.count - 1)
            let points = spectrum.enumerated().map { index, level in
                CGPoint(x: scale.x(DisplayScale.minFrequency * pow(top / DisplayScale.minFrequency, Double(index) / last)),
                        y: CGFloat(min(max(Double(level) / -90, 0), 1)) * scale.height)
            }
            context.stroke(Self.catmullRom(through: points), with: .color(color.opacity(0.6)), lineWidth: 1)
        }
        .frame(width: scale.plotWidth, height: scale.height)
        .drawingGroup()
        .allowsHitTesting(false)
    }

    /// A uniform Catmull-Rom spline through `points`, as cubic Bézier segments. The end points
    /// are repeated so the curve starts and ends exactly on them.
    static func catmullRom(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }
}
