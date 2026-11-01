import AppKit
import BreaAudioEngine
import BreaCore
import BreaDSP
import SwiftUI

/// The Parametric Equalizer page, a 1170 × 558 board in three rows.
///
/// ## Layout
/// 1. **General controls** (68 pt): Module selector, analyzer point (Pre/Post/Off), Order and
///    Bypass, output meters.
/// 2. **Equalizer** (274 pt): pre-amp fader and readout, the display, then Auto-gain, Headroom
///    compensation, Add band, Remove band and Reset.
/// 3. **Band strip** (206 pt): one ``BandPanel`` per band, scrolling horizontally.
///
/// ## Editing model
/// Controls change ``EditorModel/settings`` live (the engine hears every change) and call
/// ``EditorModel/commit(_:)`` once a gesture ends, which records one undo step.
///
/// ## Band strip interactions
/// - The mouse wheel scrolls the strip horizontally while the pointer is over it.
/// - Dragging a panel by its background moves it; the others make room as it passes their
///   slots, and the closed-hand cursor shows only while the panel is held and moving.
/// - Delete or Forward Delete removes the band under the pointer (its panel or its display
///   handle), except while a value field is being edited.
/// - Grabbing a handle on the display, or adding a band, scrolls its panel into view.
///
/// ## Performance
/// The page body never reads the signal monitor: only ``OutputMeters`` and the display's
/// spectrum layer do, so the 30 fps updates redraw those alone.
struct EQEditorView: View {
    static let boardHeight: CGFloat = 558
    private static let maximumBandCount = 31
    private static let minimumBandCount = 1
    private static let buttonWidth: CGFloat = 80
    private static let bandButtonWidth: CGFloat = 96
    private static let panelStride = BandPanel.width + Reloj.Space.panelGap
    private static let deleteKeyCodes: Set<UInt16> = [51, 117]
    /// The band strip's visible frame, which stays put while panels move and reorder.
    private static let stripSpace = "BandStrip"
    private static let analyzerOptions = [RelojOption(value: AnalyzerPoint.pre, label: "Pre"),
                                          RelojOption(value: AnalyzerPoint.post, label: "Post"),
                                          RelojOption(value: AnalyzerPoint.off, label: "Off")]

    let model: EditorModel

    @State private var module = "Parametric Equalizer"
    @State private var hoveredBand: EQBand.ID?
    @State private var displayHoveredBand: EQBand.ID?
    @State private var monitor = SignalMonitor()
    @State private var stripPosition = ScrollPosition(idType: EQBand.ID.self)
    @State private var stripOffset: CGFloat = 0
    @State private var stripMaxOffset: CGFloat = 0
    @State private var isOverStrip = false
    @State private var eventMonitors: [Any] = []
    @State private var draggedBand: EQBand.ID?
    @State private var dragStartIndex = 0
    @State private var dragOffset: CGFloat = 0

    @Environment(\.undoManager) private var undoManager

    private var controller: AudioEngineController { model.controller }
    private var settings: Binding<ChainSettings> { model.settingsBinding }
    private var isBypassed: Bool { model.settings.isBypassed }

    var body: some View {
        VStack(spacing: 0) {
            generalControls
            equalizer
            bandStrip
        }
        .frame(width: Reloj.Size.canvasWide, height: Self.boardHeight, alignment: .top)
        .foregroundStyle(Reloj.Palette.label)
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) })
        .task(id: model.key) {
            await monitor.run(probes: { [controller, model] in controller.activeProbes(fallback: model.key) },
                              sampleRate: { [controller] in controller.sampleRate })
        }
        .onAppear {
            model.undoManager = undoManager
            model.history.reset(to: model.settings)
            installEventMonitors()
        }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .onDisappear {
            eventMonitors.forEach(NSEvent.removeMonitor)
            eventMonitors = []
        }
    }

    // MARK: General controls

    private var generalControls: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: Reloj.Space.canvasMargin) {
                RelojBoxedSelector(label: "Módulo", options: ["Parametric Equalizer"], selection: $module, width: 200)
                RelojSegmented(accessibilityName: "Analyzer", options: Self.analyzerOptions,
                               selection: analyzerBinding, width: 170)
            }
            .frame(height: Reloj.Size.selectorBox)
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 0) {
                HStack(spacing: Reloj.Space.buttonGap) {
                    RelojButton(title: "Order", width: Self.buttonWidth, action: orderBands)
                        .help("Order the panels by frequency, low to high")
                    RelojToggleButton(title: "Bypass", isOn: bypassBinding, width: Self.buttonWidth)
                        .keyboardShortcut("b", modifiers: [])
                }
                .padding(.top, 13)
                OutputMeters(monitor: monitor)
                    .padding(.leading, 20)
                    .padding(.trailing, -6)
            }
            .frame(height: Reloj.Size.selectorBox, alignment: .top)
        }
        .padding([.top, .horizontal], Reloj.Space.canvasMargin)
        .frame(height: 68, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("General controls")
    }

    // MARK: Equalizer

    private var equalizer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    RelojFader(accessibilityName: "Pre-amp", value: pregainBinding, range: -12...12, bipolar: true,
                               defaultValue: 0, valueText: "\(Reloj.formatGain(model.settings.pregainDB)) dB",
                               height: 172, isDisabled: isBypassed, onCommit: { model.commit("Change Pre-amp") })
                    RelojReadout(label: "Pre-amp", value: pregainBinding, range: -12...12, defaultValue: 0,
                                 format: Reloj.formatGain, unit: "dB", width: 60, isDisabled: isBypassed,
                                 onCommit: { model.commit("Change Pre-amp") })
                        .padding(.top, 6)
                }
                .frame(width: 60)
                EqualizerDisplay(label: "Parametric Equalizer", width: 1_068, height: 160, gainRange: -12...12, gainStep: 6,
                                 bands: model.settings.bands.filter(\.isEnabled),
                                 offset: model.settings.pregainDB, sampleRate: controller.sampleRate,
                                 highlighted: hoveredBand, isDisabled: isBypassed, monitor: monitor,
                                 onHoverChange: { displayHoveredBand = $0 },
                                 onSelect: revealPanel, onHandleChange: moveHandle, onCommit: { model.commit("Move Band") })
                    .padding(.leading, 2)
                    .padding(.top, 6)
            }
            .padding(.horizontal, Reloj.Space.canvasMargin)
            .frame(height: 210.6, alignment: .top)

            HStack(spacing: 0) {
                HStack(spacing: Reloj.Space.buttonGap) {
                    RelojToggleButton(title: "Auto-gain", isOn: autoGainBinding, width: Self.buttonWidth)
                    RelojToggleButton(title: "Headroom compensation", isOn: headroomBinding)
                }
                .disabled(isBypassed)
                RelojDivider(length: 32)
                    .padding(.horizontal, Reloj.Space.canvasMargin)
                HStack(spacing: Reloj.Space.buttonGap) {
                    RelojButton(title: "Add band", width: Self.bandButtonWidth, action: addBand)
                        .disabled(isBypassed || model.settings.bands.count >= Self.maximumBandCount)
                    RelojButton(title: "Remove band", width: Self.bandButtonWidth, action: removeLastBand)
                        .disabled(isBypassed || model.settings.bands.count <= Self.minimumBandCount)
                }
                Spacer(minLength: 0)
                RelojButton(title: "Reset", width: Self.buttonWidth, action: resetEqualizer)
                    .disabled(isBypassed)
            }
            .frame(height: Reloj.Size.control)
            .padding(.top, 11.4)
        }
        .padding(.top, 20)
        .padding(.horizontal, Reloj.Space.canvasMargin)
        .frame(height: 274, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Equalizer")
    }

    // MARK: Band strip

    private var bandStrip: some View {
        let indices = Dictionary(uniqueKeysWithValues: model.settings.bands.enumerated().map { ($1.id, $0) })
        return ScrollView(.horizontal) {
            HStack(spacing: Reloj.Space.panelGap) {
                ForEach(settings.bands) { $band in
                    let id = band.id
                    let index = indices[id] ?? 0
                    let isDragged = draggedBand == id
                    BandPanel(title: "Band \(index + 1)", band: $band,
                              defaultFrequency: ChainSettings.defaultFrequencies[min(index, ChainSettings.defaultFrequencies.count - 1)],
                              isInactive: isBypassed, onCommit: { model.commit("Edit Band") })
                        .offset(x: isDragged ? dragOffset : 0)
                        .zIndex(isDragged ? 1 : 0)
                        .onHover { isHovering in
                            if isHovering { hoveredBand = id } else if hoveredBand == id { hoveredBand = nil }
                        }
                        .gesture(panelDrag(id), isEnabled: !isBypassed)
                        .id(id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, Reloj.Space.canvasMargin)
        }
        .coordinateSpace(.named(Self.stripSpace))
        .scrollIndicators(.never)
        .scrollPosition($stripPosition)
        .onScrollGeometryChange(for: CGSize.self) { geometry in
            CGSize(width: geometry.contentOffset.x, height: max(0, geometry.contentSize.width - geometry.containerSize.width))
        } action: { _, value in
            stripOffset = value.width
            stripMaxOffset = value.height
        }
        .onHover { isOverStrip = $0 }
        .padding(.top, 25)
        .frame(height: 206, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bands")
    }

    /// Reordering by dragging a panel.
    ///
    /// ## Steps
    /// 1. After 4 pt of movement the panel is picked up: its start index is remembered and the
    ///    closed-hand cursor is pushed.
    /// 2. The translation, in panel strides, gives the target slot; when it changes, the band
    ///    moves there (animated) and the other panels slide to make room.
    /// 3. The panel's offset is the translation minus the slots already moved, so it stays
    ///    under the pointer.
    /// 4. On release the cursor pops, the panel settles and, if the order changed, one undo step
    ///    is recorded.
    ///
    /// The translation is measured in the strip's frame, not the panel's: the panel itself moves
    /// (offset and new slot), and measuring in its own space would feed that movement back into
    /// the translation and make neighbouring slots swap back and forth.
    private func panelDrag(_ id: EQBand.ID) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.stripSpace))
            .onChanged { gesture in
                var next = model.settings
                guard let current = next.bands.firstIndex(where: { $0.id == id }) else { return }
                if draggedBand == nil {
                    draggedBand = id
                    dragStartIndex = current
                    NSCursor.closedHand.push()
                }
                let steps = Int((gesture.translation.width / Self.panelStride).rounded())
                let target = min(max(dragStartIndex + steps, 0), next.bands.count - 1)
                if target != current {
                    next.bands.insert(next.bands.remove(at: current), at: target)
                    withAnimation(.snappy(duration: 0.2)) { model.setSettings(next) }
                }
                dragOffset = gesture.translation.width - CGFloat(target - dragStartIndex) * Self.panelStride
            }
            .onEnded { _ in
                guard draggedBand != nil else { return }
                NSCursor.pop()
                let moved = model.settings.bands.firstIndex { $0.id == id } != dragStartIndex
                draggedBand = nil
                withAnimation(.snappy(duration: 0.2)) { dragOffset = 0 }
                if moved { model.commit("Move Band") }
            }
    }

    /// Installs the two local event monitors (wheel → strip, Delete → band under the pointer).
    /// Events they do not consume continue to the window unchanged.
    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }
        let wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let deltaX = event.scrollingDeltaX, deltaY = event.scrollingDeltaY
            let isPrecise = event.hasPreciseScrollingDeltas
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard isOverStrip, abs(deltaY) > abs(deltaX) else { return false }
                let step = isPrecise ? deltaY : deltaY * 10
                stripPosition.scrollTo(x: min(max(stripOffset - step, 0), stripMaxOffset))
                return true
            }
            return consumed ? nil : event
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.deleteKeyCodes.contains(event.keyCode) else { return event }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard !(NSApp.keyWindow?.firstResponder is NSTextView) else { return false }
                return deleteBandUnderPointer()
            }
            return consumed ? nil : event
        }
        eventMonitors = [wheel, keys].compactMap { $0 }
    }

    private func revealPanel(_ id: EQBand.ID) {
        withAnimation { stripPosition.scrollTo(id: id) }
    }

    /// A handle drag: frequency always, gain only for types that have one.
    private func moveHandle(_ id: EQBand.ID, _ frequency: Double, _ gain: Double) {
        var next = model.settings
        guard let index = next.bands.firstIndex(where: { $0.id == id }) else { return }
        next.bands[index].frequency = frequency
        if next.bands[index].type.usesGain { next.bands[index].gainDB = min(max(gain, -12), 12) }
        model.setSettings(next)
    }

    // MARK: Actions

    /// Appends the default band for the next position and scrolls to it once it is laid out.
    private func addBand() {
        var next = model.settings
        guard next.bands.count < Self.maximumBandCount else { return }
        let band = ChainSettings.defaultBand(at: next.bands.count)
        next.bands.append(band)
        model.setSettings(next)
        model.commit("Add Band")
        DispatchQueue.main.async { withAnimation { stripPosition.scrollTo(id: band.id) } }
    }

    private func removeLastBand() {
        guard let last = model.settings.bands.last else { return }
        removeBand(last.id, actionName: "Remove Band")
    }

    /// Removes a band, always keeping at least one.
    private func removeBand(_ id: EQBand.ID, actionName: String) {
        var next = model.settings
        guard next.bands.count > Self.minimumBandCount else { return }
        next.bands.removeAll { $0.id == id }
        if hoveredBand == id { hoveredBand = nil }
        if displayHoveredBand == id { displayHoveredBand = nil }
        model.setSettings(next)
        model.commit(actionName)
    }

    private func deleteBandUnderPointer() -> Bool {
        guard !isBypassed, let id = hoveredBand ?? displayHoveredBand else { return false }
        removeBand(id, actionName: "Delete Band")
        return true
    }

    /// Sorts the panels by frequency, low to high. The sound does not change: the sections are
    /// in series, and series filters commute.
    private func orderBands() {
        var next = model.settings
        let ordered = next.bands.sorted { $0.frequency < $1.frequency }
        guard ordered.map(\.id) != next.bands.map(\.id) else { return }
        next.bands = ordered
        withAnimation(.snappy(duration: 0.25)) { model.setSettings(next) }
        model.commit("Order Bands")
    }

    /// Every band back to its position's default (a flat bell at the default frequency, Q 1),
    /// the pre-amp to 0 dB and Auto-gain off. The number of bands is kept.
    private func resetEqualizer() {
        var next = model.settings
        next.bands = next.bands.indices.map { ChainSettings.defaultBand(at: $0) }
        next.pregainDB = 0
        next.isAutoPregain = false
        model.setSettings(next)
        model.commit("Reset")
    }

    // MARK: Bindings

    private var analyzerBinding: Binding<AnalyzerPoint> {
        Binding { controller.analyzer } set: { controller.setAnalyzer($0) }
    }

    private var bypassBinding: Binding<Bool> {
        Binding { model.settings.isBypassed } set: { settings.wrappedValue.isBypassed = $0 }
    }

    /// Moving the pre-amp by hand turns Auto-gain off.
    private var pregainBinding: Binding<Double> {
        Binding {
            model.settings.pregainDB
        } set: { value in
            var next = model.settings
            next.isAutoPregain = false
            next.pregainDB = value
            model.setSettings(next)
        }
    }

    private var autoGainBinding: Binding<Bool> {
        Binding {
            model.settings.isAutoPregain
        } set: { isOn in
            settings.wrappedValue.isAutoPregain = isOn
            model.commit("Auto-gain")
        }
    }

    private var headroomBinding: Binding<Bool> {
        Binding {
            model.settings.headroom == .auto
        } set: { isOn in
            settings.wrappedValue.headroom = isOn ? .auto : .manual(dB: 0)
            model.commit("Headroom Compensation")
        }
    }
}

/// The "Out" label and the left/right meters (the right one carries the dB scale).
///
/// Levels map −60…0 dBFS onto the bar; the peak line is hidden while it rests on the floor.
/// This view is the only reader of the monitor's levels, so meter updates redraw it alone.
private struct OutputMeters: View {
    let monitor: SignalMonitor

    private static let marks: [RelojMeter.Mark] = [-60, -48, -36, -24, -12, 0].map {
        RelojMeter.Mark(position: (Double($0) + 60) / 60, label: String($0))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("Out")
                .font(Reloj.Typeface.label)
                .foregroundStyle(Reloj.Palette.dim)
                .frame(height: 14)
                .padding(.top, 12.39)
            VStack(spacing: 4) {
                meter("Out L", monitor.left, marks: [])
                meter("Out R", monitor.right, marks: Self.marks)
            }
            .padding(.top, 8.4)
        }
    }

    private func meter(_ name: String, _ level: SignalMonitor.Level, marks: [RelojMeter.Mark]) -> some View {
        let floor = SignalMonitor.floorDB
        return RelojMeter(accessibilityName: name, level: (level.level - floor) / -floor,
                          peak: level.peak > floor ? (level.peak - floor) / -floor : nil,
                          valueText: "\(Reloj.formatGain(level.level)) dB", marks: marks)
    }
}
