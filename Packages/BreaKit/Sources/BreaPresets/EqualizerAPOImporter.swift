import BreaDSP
import Foundation

/// Reads Equalizer APO configuration text, as written by Brea, AutoEq, REW, Peace and others.
///
/// ## Supported commands
/// - `Preamp: <dB> dB` — several lines add up.
/// - `Filter[ n]: ON|OFF <type> Fc <Hz> Hz [Gain <dB> dB] [Q <q> | BW Oct <octaves>]` with
///   types `PK`/`PEQ`/`Modal`, `LP`/`LPQ`, `HP`/`HPQ`, `LS`/`LSC`, `HS`/`HSC` (optionally
///   `6dB`/`12dB`) and `NO`. Missing Q values get each type's usual default.
/// - `GraphicEQ: <Hz> <dB>; …` — fitted to parametric bands by ``GraphicEQFitter``.
/// - `# Brea: AutoGain On|Off` and `# Brea: HeadroomCompensation On|Off`.
///
/// Anything else (`Channel`, `Device`, `Include`, `Delay`, `Convolution`…) is skipped with a
/// warning; filters always apply to every channel.
///
/// ## Steps
/// 1. Strip a UTF-8 byte-order mark (common in files saved on Windows).
/// 2. For each line, read Brea extensions first; otherwise drop the `#` comment and split the
///    command from its body at the first colon.
/// 3. Collect pre-amp, bands and graphic points, recording a warning per unreadable line.
/// 4. Throw ``ImportError/nothingFound`` when no line was usable.
/// 5. Keep at most `maxBands` filters, then spend the remaining bands on the GraphicEQ fit; the
///    fit's overall level goes into the pre-amp.
///
/// The pre-amp is taken exactly as written: importing never rescales the level on its own.
public enum EqualizerAPOImporter {
    public struct Result: Sendable {
        public var settings: ChainSettings
        /// Human-readable notes about every line that was skipped or approximated.
        public var warnings: [String]
    }

    public enum ImportError: LocalizedError {
        case nothingFound

        public var errorDescription: String? {
            "The file has no Equalizer APO Preamp, Filter or GraphicEQ lines."
        }
    }

    public static func parse(_ text: String, maxBands: Int = ProcessingChain.maxBands) throws -> Result {
        var pregain = 0.0
        var bands: [EQBand] = []
        var graphic: [(frequency: Double, gainDB: Double)] = []
        var warnings: [String] = []
        var foundAnything = false
        var isAutoPregain = false
        var headroom = ChainSettings.Headroom.manual(dB: 0)

        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            if let extensionLine = EqualizerAPOExporter.breaExtension(in: rawLine) {
                switch extensionLine {
                case ("autogain", let value): isAutoPregain = value == "on"
                case ("headroomcompensation", let value): headroom = value == "on" ? .auto : .manual(dB: 0)
                default: break
                }
                continue
            }
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard let colon = line.firstIndex(of: ":") else { continue }
            let command = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let body = String(line[line.index(after: colon)...])
            let lineNumber = index + 1

            switch command.split(separator: " ").first.map(String.init) ?? "" {
            case "preamp":
                guard let value = firstNumber(in: body) else {
                    warnings.append("Line \(lineNumber): unreadable Preamp.")
                    continue
                }
                pregain += value
                foundAnything = true
            case "filter":
                do {
                    if let band = try filter(from: body) {
                        bands.append(band)
                        foundAnything = true
                    }
                } catch let issue as FilterIssue {
                    warnings.append("Line \(lineNumber): \(issue.text)")
                }
            case "graphiceq":
                let points = body.split(separator: ";").compactMap { pair -> (Double, Double)? in
                    let numbers = pair.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
                    return numbers.count >= 2 ? (numbers[0], numbers[1]) : nil
                }
                if points.isEmpty {
                    warnings.append("Line \(lineNumber): GraphicEQ has no points.")
                } else {
                    graphic.append(contentsOf: points)
                    foundAnything = true
                }
            case "channel":
                warnings.append("Line \(lineNumber): Channel selection is ignored; filters apply to every channel.")
            default:
                warnings.append("Line \(lineNumber): \"\(command.capitalized)\" is not supported and was skipped.")
            }
        }

        guard foundAnything else { throw ImportError.nothingFound }

        if bands.count > maxBands {
            warnings.append("Only the first \(maxBands) of \(bands.count) filters were imported.")
            bands = Array(bands.prefix(maxBands))
        }
        if !graphic.isEmpty {
            let room = maxBands - bands.count
            if room > 0 {
                let fit = GraphicEQFitter.fit(graphic, maxBands: room)
                bands += fit.bands
                pregain += fit.offsetDB
                if fit.maxErrorDB > 0.5 {
                    warnings.append(String(format: "GraphicEQ approximated with %d bands (max deviation %.1f dB).",
                                           fit.bands.count, fit.maxErrorDB))
                }
            } else {
                warnings.append("No bands left for the GraphicEQ curve; it was skipped.")
            }
        }

        return Result(settings: ChainSettings(bands: bands, pregainDB: pregain, headroom: headroom, isAutoPregain: isAutoPregain),
                      warnings: warnings)
    }

    // MARK: - Filters

    private struct FilterIssue: Error {
        let text: String
    }

    /// Parses the body of a `Filter:` line.
    ///
    /// Keywords are matched case-insensitively wherever they appear, so the order of `Fc`,
    /// `Gain` and `Q` does not matter. A bandwidth in octaves converts to
    /// `Q = 2^(N/2) / (2^N − 1)`.
    ///
    /// - Returns: The band, or `nil` for APO's empty filter type `NONE`.
    private static func filter(from body: String) throws -> EQBand? {
        let tokens = body.split(whereSeparator: \.isWhitespace).map { String($0) }
        guard tokens.count >= 2 else { throw FilterIssue(text: "incomplete filter.") }
        let isEnabled = tokens[0].uppercased() != "OFF"
        let kind = tokens[1].uppercased()

        func value(after keyword: String) -> Double? {
            guard let index = tokens.firstIndex(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }),
                  index + 1 < tokens.count else { return nil }
            let next = tokens[index + 1]
            if next.caseInsensitiveCompare("Oct") == .orderedSame, index + 2 < tokens.count { return Double(tokens[index + 2]) }
            return Double(next)
        }

        guard let frequency = value(after: "Fc"), frequency > 0 else {
            if kind == "NONE" { return nil }
            throw FilterIssue(text: "\(kind) filter without Fc was skipped.")
        }
        let gain = value(after: "Gain") ?? 0
        let q: Double? = value(after: "Q") ?? value(after: "BW").map { bandwidth in
            pow(2, bandwidth / 2) / (pow(2, bandwidth) - 1)
        }
        let isGentleShelf = tokens.contains { $0.caseInsensitiveCompare("6dB") == .orderedSame }

        var band: EQBand
        switch kind {
        case "PK", "PEQ", "MODAL":
            band = EQBand(type: .peak, frequency: frequency, gainDB: gain, q: q ?? 1.41)
        case "LP", "LPQ":
            band = EQBand(type: .lowPass, frequency: frequency, q: q ?? 0.7071)
        case "HP", "HPQ":
            band = EQBand(type: .highPass, frequency: frequency, q: q ?? 0.7071)
        case "LS", "LSC":
            band = EQBand(type: .lowShelf, frequency: frequency, gainDB: gain, q: q ?? (isGentleShelf ? 0.5 : 0.7071))
        case "HS", "HSC":
            band = EQBand(type: .highShelf, frequency: frequency, gainDB: gain, q: q ?? (isGentleShelf ? 0.5 : 0.7071))
        case "NO":
            band = EQBand(type: .notch, frequency: frequency, q: q ?? 30)
        default:
            throw FilterIssue(text: "filter type \(kind) is not supported and was skipped.")
        }
        band.isEnabled = isEnabled
        return band
    }

    private static func firstNumber(in text: String) -> Double? {
        text.split(whereSeparator: \.isWhitespace).lazy.compactMap { Double($0) }.first
    }
}
