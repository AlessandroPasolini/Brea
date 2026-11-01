import BreaCore
import Foundation

/// Everything that defines how the equalizer sounds, plus bypass.
///
/// ## Gain staging
/// By default the chain is unity gain: the output level follows the system volume. The level
/// only changes when the user moves the Pre-amp, turns on Auto-gain (which drives the Pre-amp)
/// or turns on Headroom compensation (an automatic output trim).
///
/// ## Decoding
/// Missing keys fall back to their defaults, so settings saved by earlier versions keep loading.
public struct ChainSettings: Equatable, Codable, Sendable {
    /// The output trim applied after the equalizer.
    public enum Headroom: Equatable, Codable, Sendable {
        /// Headroom compensation: computed from the full response so the chain cannot clip.
        case auto
        /// A fixed trim in decibels; values above 0 count as 0. The editor only uses `0`.
        case manual(dB: Double)
    }

    public var bands: [EQBand]
    /// Pre-amp gain in decibels, applied before the bands.
    public var pregainDB: Double
    public var headroom: Headroom
    /// Auto-gain: while on, the editor keeps ``pregainDB`` at ``compensatingPregainDB(sampleRate:)``.
    public var isAutoPregain: Bool
    public var isBypassed: Bool

    public init(bands: [EQBand] = [], pregainDB: Double = 0, headroom: Headroom = .manual(dB: 0),
                isAutoPregain: Bool = false, isBypassed: Bool = false) {
        self.bands = bands
        self.pregainDB = pregainDB
        self.headroom = headroom
        self.isAutoPregain = isAutoPregain
        self.isBypassed = isBypassed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bands = try c.decodeIfPresent([EQBand].self, forKey: .bands) ?? []
        pregainDB = try c.decodeIfPresent(Double.self, forKey: .pregainDB) ?? 0
        headroom = try c.decodeIfPresent(Headroom.self, forKey: .headroom) ?? .manual(dB: 0)
        isAutoPregain = try c.decodeIfPresent(Bool.self, forKey: .isAutoPregain) ?? false
        isBypassed = try c.decodeIfPresent(Bool.self, forKey: .isBypassed) ?? false
    }

    /// The Pre-amp that pulls the loudest point of the band curve back down to 0 dB.
    /// It only ever lowers the level: a curve that stays below 0 dB gives 0.
    public func compensatingPregainDB(sampleRate: Double) -> Double {
        -max(0, EQResponse(bands: bands, sampleRate: sampleRate).peakDecibels())
    }

    /// The default frequency of the band at each position: the first eight an octave apart,
    /// then the remaining ISO third-octave centres from low to high (31 positions).
    public static let defaultFrequencies: [Double] = [
        63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000,
        20, 25, 31.5, 40, 50, 80, 100, 160, 200, 315, 400, 630, 800, 1_250, 1_600, 2_500, 3_150, 5_000,
        6_300, 10_000, 12_500, 16_000, 20_000,
    ]

    /// A flat bell (0 dB, Q 1) at the default frequency of position `index`.
    public static func defaultBand(at index: Int) -> EQBand {
        let frequencies = defaultFrequencies
        return EQBand(type: .peak, frequency: frequencies[min(max(index, 0), frequencies.count - 1)], gainDB: 0, q: 1)
    }

    /// Eight flat bells an octave apart. Stored, not computed, so its band identities stay stable
    /// across reads.
    public static let standard = ChainSettings(bands: (0..<8).map { defaultBand(at: $0) })

    /// Whether both settings sound the same, ignoring band identity and bypass.
    public func hasSameSound(as other: ChainSettings) -> Bool {
        pregainDB == other.pregainDB && headroom == other.headroom && bands.count == other.bands.count
            && zip(bands, other.bands).allSatisfy { $0.hasSameParameters(as: $1) }
    }
}

/// The equalizer's real-time processing: Pre-amp → bands → effect slots → headroom → clip guard.
///
/// ## Parameter flow
/// 1. A control thread calls ``update(_:)`` with new ``ChainSettings``.
/// 2. ``publish()`` turns them into a flat snapshot of doubles:
///    `[bypass, pregain, headroom, b0 b1 b2 a1 a2, …]`, with gains already linear and the
///    headroom already resolved.
/// 3. The snapshot goes through a ``ParameterMailbox``, never blocking either side.
/// 4. At the start of each block the audio thread consumes the newest snapshot and sets the
///    targets of its gain stages and of the ``ParametricEQ``; every change then glides over that
///    block.
///
/// ## Per block (``process(_:channelCount:frameCount:)``)
/// 1. Apply any new snapshot.
/// 2. Feed the analyzer if it listens before the EQ.
/// 3. Unless fully bypassed (bypass on and every stage at rest), run Pre-amp, bands, effects,
///    headroom and the clip guard in place.
/// 4. Feed the analyzer if it listens after the EQ.
/// 5. Record the left and right output peaks.
///
/// ## Threading
/// `update` and `prepare` run on one control thread; `prepare` and `reset` never overlap
/// `process`, which runs on the audio thread.
public final class ProcessingChain: AudioProcessor, @unchecked Sendable {
    /// Bands the chain can hold; one biquad section each.
    public static let maxBands = 32
    private static let headerCount = 3

    public let probes: ChainProbes

    private let mailbox = ParameterMailbox<Double>(capacity: headerCount + maxBands * 5, initial: 0)
    private let eq = ParametricEQ(maxBands: maxBands)
    private let effects: ContiguousArray<any AudioProcessor>

    private var sampleRate = 48_000.0
    private var settings = ChainSettings()
    private var scratch: [Double] = []

    private var pregain = GainStage()
    private var headroom = GainStage()
    private var bypassed = false

    /// - Parameters:
    ///   - effects: Stages inserted after the bands, in order.
    ///   - probes: Meters and analyzer feed; share one instance across rebuilds of the same session.
    public init(effects: [any AudioProcessor] = [], probes: ChainProbes = ChainProbes()) {
        self.effects = ContiguousArray(effects)
        self.probes = probes
        publish()
        reset()
    }

    // MARK: - Control thread

    public func prepare(format: AudioFormatInfo, maxFrames: Int) {
        sampleRate = format.sampleRate
        for effect in effects { effect.prepare(format: format, maxFrames: maxFrames) }
        publish()
        reset()
    }

    public func update(_ newSettings: ChainSettings) {
        settings = newSettings
        publish()
    }

    private func publish() {
        let s = settings
        let bands = Array(s.bands.prefix(Self.maxBands))
        let headroomDB: Double = switch s.headroom {
        case .auto: HeadroomStage.autoHeadroomDB(pregainDB: s.pregainDB, bands: bands, sampleRate: sampleRate)
        case .manual(let dB): min(0, dB)
        }

        scratch.removeAll(keepingCapacity: true)
        scratch.append(s.isBypassed ? 1 : 0)
        scratch.append(s.isBypassed ? 1 : Decibels.toLinear(s.pregainDB))
        scratch.append(s.isBypassed ? 1 : Decibels.toLinear(headroomDB))
        if !s.isBypassed {
            for band in bands where band.isEnabled {
                let c = BiquadCoefficients(band, sampleRate: sampleRate)
                scratch.append(contentsOf: [c.b0, c.b1, c.b2, c.a1, c.a2])
            }
        }
        scratch.withUnsafeBufferPointer { mailbox.publish($0) }
    }

    /// Clears filter memory and snaps every stage to the newest settings, without gliding.
    public func reset() {
        if let snapshot = mailbox.consume() { applySnapshot(snapshot) }
        eq.reset(snapToTarget: true)
        pregain.current = pregain.target
        headroom.current = headroom.target
        for effect in effects { effect.reset() }
    }

    // MARK: - Audio thread

    public func process(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frameCount: Int) {
        if let snapshot = mailbox.consume() { applySnapshot(snapshot) }
        if probes.isAnalyzingPre { probes.spectrum.write(channels, channelCount: channelCount, frameCount: frameCount) }

        if !(bypassed && pregain.isUnity && headroom.isUnity && eq.isIdentity) {
            pregain.apply(channels, channelCount: channelCount, frameCount: frameCount)
            eq.process(channels, channelCount: channelCount, frameCount: frameCount)
            for i in effects.indices { effects[i].process(channels, channelCount: channelCount, frameCount: frameCount) }
            headroom.apply(channels, channelCount: channelCount, frameCount: frameCount)
            ClipGuard.apply(channels, channelCount: channelCount, frameCount: frameCount)
        }

        if probes.isAnalyzingPost { probes.spectrum.write(channels, channelCount: channelCount, frameCount: frameCount) }
        guard channelCount > 0 else { return }
        probes.outputLeft.record(Self.peak(channels[0], frameCount))
        probes.outputRight.record(Self.peak(channels[min(1, channelCount - 1)], frameCount))
    }

    private func applySnapshot(_ p: UnsafeBufferPointer<Double>) {
        guard p.count >= Self.headerCount, let base = p.baseAddress else { return }
        bypassed = base[0] != 0
        pregain.target = Float(base[1])
        headroom.target = Float(base[2])
        eq.setTarget(base + Self.headerCount, bandCount: (p.count - Self.headerCount) / 5)
    }

    private static func peak(_ x: UnsafeMutablePointer<Float>, _ n: Int) -> Float {
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(x[i])) }
        return peak
    }
}
