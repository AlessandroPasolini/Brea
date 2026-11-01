import BreaDSP
import Foundation

/// Writes Brea's document format: an Equalizer APO configuration that any APO host can read.
///
/// ## Output
/// ```
/// # Equalizer APO configuration exported by Brea
/// Preamp: -3.5 dB
/// Filter 1: ON PK Fc 1000 Hz Gain 4 dB Q 1.41
/// Filter 2: OFF HPQ Fc 30 Hz Q 0.707
/// # Brea: AutoGain On
/// # Brea: HeadroomCompensation Off
/// ```
/// 1. A header comment.
/// 2. `Preamp:` with the pre-amp gain.
/// 3. One `Filter n:` line per band, in panel order, `ON` or `OFF` (disabled bands are kept).
///    Types map to `PK`, `LSC`, `HSC`, `LPQ`, `HPQ` and `NO`; gain is written only for types
///    that use it.
/// 4. Settings APO has no syntax for, as `# Brea:` comments. APO hosts ignore comments and
///    ``EqualizerAPOImporter`` reads them back, so a document round-trips without loss.
///
/// Numbers always use a dot as decimal separator, drop trailing zeros and never read `-0`.
public enum EqualizerAPOExporter {
    public static let fileExtension = "txt"

    public static func export(_ settings: ChainSettings) -> String {
        var lines = ["# Equalizer APO configuration exported by Brea"]
        lines.append("Preamp: \(number(settings.pregainDB, decimals: 1)) dB")
        for (index, band) in settings.bands.enumerated() {
            lines.append("Filter \(index + 1): \(band.isEnabled ? "ON" : "OFF") \(filter(band))")
        }
        lines.append("# Brea: AutoGain \(settings.isAutoPregain ? "On" : "Off")")
        lines.append("# Brea: HeadroomCompensation \(settings.headroom == .auto ? "On" : "Off")")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The lower-cased `(key, value)` of a `# Brea: Key Value` line, `("", "")` for a malformed
    /// one, or `nil` when the line is not a Brea extension.
    static func breaExtension(in line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("# brea:") else { return nil }
        let parts = trimmed.dropFirst("# brea:".count).split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        return parts.count >= 2 ? (parts[0], parts[1]) : ("", "")
    }

    private static func filter(_ band: EQBand) -> String {
        let fc = "Fc \(number(band.frequency, decimals: band.frequency < 100 ? 1 : 0)) Hz"
        let gain = "Gain \(number(band.gainDB, decimals: 1)) dB"
        let q = "Q \(number(band.q, decimals: 3))"
        switch band.type {
        case .peak: return "PK \(fc) \(gain) \(q)"
        case .lowShelf: return "LSC \(fc) \(gain) \(q)"
        case .highShelf: return "HSC \(fc) \(gain) \(q)"
        case .lowPass: return "LPQ \(fc) \(q)"
        case .highPass: return "HPQ \(fc) \(q)"
        case .notch: return "NO \(fc) \(q)"
        }
    }

    private static func number(_ value: Double, decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}
