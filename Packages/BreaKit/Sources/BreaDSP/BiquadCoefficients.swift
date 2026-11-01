import Foundation

/// The shape of one equalizer band.
public enum FilterType: String, CaseIterable, Codable, Sendable {
    case peak, lowShelf, highShelf, lowPass, highPass, notch

    /// Whether the band has a gain parameter. Pass and notch filters only have frequency and Q.
    public var usesGain: Bool {
        switch self {
        case .peak, .lowShelf, .highShelf: true
        case .lowPass, .highPass, .notch: false
        }
    }
}

/// One band of the parametric equalizer, as edited by the user.
///
/// ## Decoding
/// Missing keys fall back to their defaults and filter types that no longer exist (Band Pass)
/// load as ``FilterType/peak``, so settings written by any earlier version keep loading.
public struct EQBand: Identifiable, Equatable, Codable, Sendable {
    /// Stable identity used by the editor for hover, drag and panel positions.
    public var id: UUID
    public var type: FilterType
    /// Centre or corner frequency, in hertz.
    public var frequency: Double
    /// Gain in decibels; ignored by types without gain.
    public var gainDB: Double
    /// Quality factor (bandwidth for bells and notches, resonance for shelves and passes).
    public var q: Double
    /// An off band is kept but contributes nothing to the sound.
    public var isEnabled: Bool

    public init(id: UUID = UUID(), type: FilterType = .peak, frequency: Double = 1_000, gainDB: Double = 0,
                q: Double = 1, isEnabled: Bool = true) {
        self.id = id
        self.type = type
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
        self.isEnabled = isEnabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = (try c.decodeIfPresent(String.self, forKey: .type)).flatMap(FilterType.init(rawValue:)) ?? .peak
        frequency = try c.decodeIfPresent(Double.self, forKey: .frequency) ?? 1_000
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        q = try c.decodeIfPresent(Double.self, forKey: .q) ?? 1
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    /// Whether both bands sound the same, ignoring their identity.
    public func hasSameParameters(as other: EQBand) -> Bool {
        type == other.type && frequency == other.frequency && gainDB == other.gainDB
            && q == other.q && isEnabled == other.isEnabled
    }
}

/// The five normalized coefficients of a second-order IIR section (RBJ Audio EQ Cookbook).
///
/// ## Computation
/// 1. Clamp the frequency to (0, 0.499 · fs) and derive ω₀, cos ω₀ and sin ω₀.
/// 2. Compute α = sin ω₀ / 2Q and, for shelves and bells, A = 10^(gain/40).
/// 3. Evaluate the cookbook formulas for the band's ``FilterType``.
/// 4. Divide every coefficient by a₀, so `a0` is implicitly 1.
///
/// All arithmetic is 64-bit; the audio itself stays 32-bit float.
public struct BiquadCoefficients: Equatable, Sendable {
    public var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    /// The identity (pass-through) section.
    public init() {}

    /// The section realizing `band` at sample rate `fs`; the identity when the band is off.
    public init(_ band: EQBand, sampleRate fs: Double) {
        guard band.isEnabled else { return }
        let f = min(max(band.frequency, 1), fs * 0.499)
        let w0 = 2 * Double.pi * f / fs
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * max(band.q, 0.01))
        let A = pow(10, band.gainDB / 40)
        let sq = 2 * A.squareRoot() * alpha

        let b0, b1, b2, a0, a1, a2: Double
        switch band.type {
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * cosw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cosw; a2 = 1 - alpha / A
        case .lowShelf:
            b0 = A * ((A + 1) - (A - 1) * cosw + sq)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosw)
            b2 = A * ((A + 1) - (A - 1) * cosw - sq)
            a0 = (A + 1) + (A - 1) * cosw + sq
            a1 = -2 * ((A - 1) + (A + 1) * cosw)
            a2 = (A + 1) + (A - 1) * cosw - sq
        case .highShelf:
            b0 = A * ((A + 1) + (A - 1) * cosw + sq)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosw)
            b2 = A * ((A + 1) + (A - 1) * cosw - sq)
            a0 = (A + 1) - (A - 1) * cosw + sq
            a1 = 2 * ((A - 1) - (A + 1) * cosw)
            a2 = (A + 1) - (A - 1) * cosw - sq
        case .lowPass:
            b0 = (1 - cosw) / 2; b1 = 1 - cosw; b2 = (1 - cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosw) / 2; b1 = -(1 + cosw); b2 = (1 + cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * cosw; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        }
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0
        self.a1 = a1 / a0; self.a2 = a2 / a0
    }

    /// Magnitude |H(e^jω)| in decibels at frequency `f`, evaluated on the unit circle.
    public func magnitudeDB(at f: Double, sampleRate fs: Double) -> Double {
        let w = 2 * Double.pi * f / fs
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        let mag2 = (nr * nr + ni * ni) / max(dr * dr + di * di, 1e-300)
        return 10 * log10(max(mag2, 1e-300))
    }

    /// Whether both poles lie inside the unit circle (Jury criterion for a second-order section).
    public var isStable: Bool { abs(a2) < 1 && abs(a1) < 1 + a2 }
}

/// The combined magnitude response of a list of bands plus a flat offset.
///
/// ## Overview
/// This is the single source of truth for every "how loud is the EQ at this frequency"
/// question: the editor's curves, Auto-gain, Headroom compensation and GraphicEQ fitting all
/// use it, so what is drawn always matches what is heard.
public struct EQResponse: Sendable {
    /// Coefficients of the enabled bands, in order.
    public let sections: [BiquadCoefficients]
    /// A flat gain added to the response (the Pre-amp), in decibels.
    public let offsetDB: Double
    public let sampleRate: Double

    public init(bands: [EQBand], offsetDB: Double = 0, sampleRate: Double) {
        sections = bands.filter(\.isEnabled).map { BiquadCoefficients($0, sampleRate: sampleRate) }
        self.offsetDB = offsetDB
        self.sampleRate = sampleRate
    }

    /// Response in decibels at frequency `f`: the offset plus the sum of every section.
    public func decibels(at f: Double) -> Double {
        sections.reduce(offsetDB) { $0 + $1.magnitudeDB(at: f, sampleRate: sampleRate) }
    }

    /// The loudest point of the response between 20 Hz and 20 kHz (or 0.45 · fs).
    ///
    /// ## Steps
    /// 1. Sample 512 log-spaced frequencies across the audible range.
    /// 2. Evaluate ``decibels(at:)`` at each one.
    /// 3. Return the maximum.
    public func peakDecibels() -> Double {
        let top = min(20_000, sampleRate * 0.45)
        let points = 512
        var peak = -Double.infinity
        for index in 0..<points {
            peak = max(peak, decibels(at: 20 * pow(top / 20, Double(index) / Double(points - 1))))
        }
        return peak
    }
}
