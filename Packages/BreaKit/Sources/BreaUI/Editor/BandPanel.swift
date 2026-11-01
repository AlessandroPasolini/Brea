import BreaDSP
import SwiftUI

/// The filter types offered by a band's Type menu, in menu order.
enum BandTypeOptions {
    static let all: [RelojOption<FilterType>] = [
        RelojOption(value: .peak, label: "Bell"),
        RelojOption(value: .lowShelf, label: "Low Shelf"),
        RelojOption(value: .highShelf, label: "High Shelf"),
        RelojOption(value: .highPass, label: "High Pass"),
        RelojOption(value: .lowPass, label: "Low Pass"),
        RelojOption(value: .notch, label: "Notch"),
    ]
}

/// One band's panel (356 × 181).
///
/// ## Layout
/// `[power] Band n` header, then one row: Gain knob · Q knob · divider · Frequency readout over
/// the Type selector.
///
/// ## Behaviour
/// - Every control binds straight to the band inside the editor's settings, so moving a handle
///   on the display redraws the panel and vice versa.
/// - Power off dims the marks; the controls stay operable.
/// - Bypass (`isInactive`) disables everything. Gain is also disabled for types without gain.
/// - Each finished gesture calls `onCommit`, which records one undo step.
struct BandPanel: View {
    static let width: CGFloat = 356
    static let height: CGFloat = 181
    private static let rowHeight: CGFloat = 118.21

    let title: String
    @Binding var band: EQBand
    let defaultFrequency: Double
    let isInactive: Bool
    let onCommit: () -> Void

    var body: some View {
        let isOff = !band.isEnabled
        RelojPanel(title: title, isOn: $band.isEnabled, isDisabled: isInactive,
                   width: Self.width, height: Self.height, onToggle: onCommit) {
            HStack(spacing: 0) {
                RelojKnob(label: "Gain", accessibilityName: "\(title) Gain", value: $band.gainDB, range: -12...12,
                          bipolar: true, defaultValue: 0, format: Reloj.formatGain, unit: "dB",
                          isOff: isOff, isDisabled: isInactive || !band.type.usesGain, onCommit: onCommit)
                RelojKnob(label: "Q", accessibilityName: "\(title) Q", value: $band.q, range: 0.1...10, scale: .log,
                          bipolar: true, defaultValue: 1, format: Reloj.formatQ,
                          isOff: isOff, isDisabled: isInactive, onCommit: onCommit)
                RelojDivider(length: Self.rowHeight)
                    .padding(.leading, 13)
                VStack(spacing: 0) {
                    RelojReadout(label: "Frequency", accessibilityName: "\(title) Frequency", value: $band.frequency,
                                 range: 20...20_000, scale: .log, defaultValue: defaultFrequency,
                                 format: Reloj.formatFrequency, unit: "Hz", size: .dense, width: 64,
                                 isOff: isOff, isDisabled: isInactive, onCommit: onCommit)
                    VStack(spacing: 0) {
                        Text("Type")
                            .font(Reloj.Typeface.label)
                            .foregroundStyle(isInactive ? Reloj.Palette.disabled : Reloj.Palette.label)
                            .frame(height: 14)
                        RelojSelector(accessibilityName: "\(title) Type", options: BandTypeOptions.all, selection: $band.type,
                                      isOff: isOff, isDisabled: isInactive, onCommit: onCommit)
                            .padding(.top, 2.59)
                    }
                    .padding(.top, 11.6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, Reloj.Space.panelInset)
            }
            .frame(height: Self.rowHeight)
        }
    }
}
