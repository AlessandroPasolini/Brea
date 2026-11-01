import Foundation
import Synchronization
import Testing
import BreaCore
@testable import BreaDSP

/// Runs `chain` over planar `input` in blocks, returning the processed audio.
func run(_ chain: ProcessingChain, _ input: [[Float]], block: Int = 512) -> [[Float]] {
    let frames = input[0].count
    let buffers = input.map { channel -> UnsafeMutablePointer<Float> in
        let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        p.initialize(from: channel, count: frames)
        return p
    }
    let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: buffers.count)
    defer { buffers.forEach { $0.deallocate() }; table.deallocate() }

    var start = 0
    while start < frames {
        let n = min(block, frames - start)
        for (i, b) in buffers.enumerated() { table[i] = b + start }
        chain.process(table, channelCount: buffers.count, frameCount: n)
        start += n
    }
    return buffers.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
}

func sine(_ f: Double, amplitude: Float = 0.1, frames: Int, fs: Double = 48_000) -> [Float] {
    (0..<frames).map { amplitude * Float(sin(2 * Double.pi * f * Double($0) / fs)) }
}

func rms(_ x: ArraySlice<Float>) -> Double {
    (x.reduce(0.0) { $0 + Double($1 * $1) } / Double(x.count)).squareRoot()
}

struct ChainTests {
    private func makeChain(_ settings: ChainSettings) -> ProcessingChain {
        let chain = ProcessingChain()
        chain.prepare(format: AudioFormatInfo(sampleRate: 48_000, channelCount: 2), maxFrames: 4096)
        chain.update(settings)
        chain.reset()
        return chain
    }

    @Test func peakBandBoostsSineAtCenter() {
        let chain = makeChain(ChainSettings(bands: [EQBand(frequency: 1_000, gainDB: 12, q: 1)], headroom: .manual(dB: 0)))
        let input = sine(1_000, amplitude: 0.1, frames: 48_000)
        let out = run(chain, [input, input])
        let gain = 20 * log10(rms(out[0][24_000...]) / rms(input[24_000...]))
        #expect(abs(gain - 12) < 0.05)
    }

    @Test func pregainScalesSignal() {
        let chain = makeChain(ChainSettings(pregainDB: -6, headroom: .manual(dB: 0)))
        let input = sine(500, frames: 8_192)
        let out = run(chain, [input])
        let gain = 20 * log10(rms(out[0][4_096...]) / rms(input[4_096...]))
        #expect(abs(gain + 6) < 0.01)
    }

    @Test func bypassIsBitExact() {
        let chain = makeChain(ChainSettings(bands: [EQBand(gainDB: 12)], pregainDB: 6, isBypassed: true))
        let input = sine(1_000, amplitude: 1.0, frames: 4_096)
        #expect(run(chain, [input])[0] == input)
    }

    @Test func flatChainIsBitExactUpToFullScale() {
        // Not bypassed: every stage runs, yet a hot master must come out untouched.
        let chain = makeChain(ChainSettings(bands: ChainSettings.standard.bands))
        let input = sine(1_000, amplitude: 0.999, frames: 8_192)
        #expect(run(chain, [input, input])[0] == input)
    }

    @Test func compensatingPregainCancelsTheBoost() {
        var settings = ChainSettings(bands: [EQBand(frequency: 1_000, gainDB: 6, q: 1), EQBand(frequency: 100, gainDB: -4)])
        #expect(abs(settings.compensatingPregainDB(sampleRate: 48_000) + 6) < 0.05)
        settings.bands = [EQBand(gainDB: -3)]
        #expect(settings.compensatingPregainDB(sampleRate: 48_000) == 0)   // never raises the level
    }

    @Test func retiredBandPassLoadsAsBell() throws {
        let json = #"{"bands":[{"type":"bandPass","frequency":500,"q":2,"slope":24}]}"#
        let decoded = try JSONDecoder().decode(ChainSettings.self, from: Data(json.utf8))
        #expect(decoded.bands.first?.type == .peak && decoded.bands.first?.frequency == 500)
    }

    @Test func settingsFromOlderVersionsDecode() throws {
        let json = #"{"bands":[{"type":"peak","frequency":250,"gainDB":2,"q":1}],"pregainDB":-1}"#
        let decoded = try JSONDecoder().decode(ChainSettings.self, from: Data(json.utf8))
        #expect(decoded.bands.first?.q == 1 && decoded.headroom == .manual(dB: 0) && !decoded.isAutoPregain)
    }

    @Test func defaultSettingsKeepUnityGain() {
        #expect(ChainSettings().headroom == .manual(dB: 0))
        #expect(ChainSettings.standard.pregainDB == 0)
    }

    @Test func clipGuardNeverExceedsFullScale() {
        let chain = makeChain(ChainSettings(pregainDB: 24, headroom: .manual(dB: 0)))
        let out = run(chain, [sine(300, amplitude: 1.0, frames: 8_192)])
        #expect(out[0].allSatisfy { abs($0) <= 1 })
    }

    @Test func autoHeadroomCompensatesBoost() {
        let bands = [EQBand(frequency: 1_000, gainDB: 12, q: 1)]
        let db = HeadroomStage.autoHeadroomDB(pregainDB: 0, bands: bands, sampleRate: 48_000)
        #expect(db < -11.5 && db > -12.1)
        #expect(HeadroomStage.autoHeadroomDB(pregainDB: 0, bands: [EQBand(gainDB: -6)], sampleRate: 48_000) == 0)
    }

    @Test func parameterChangeGlidesWithoutJumps() {
        let chain = makeChain(ChainSettings(headroom: .manual(dB: 0)))
        let input = sine(200, amplitude: 0.1, frames: 4_096)
        _ = run(chain, [input])
        chain.update(ChainSettings(pregainDB: 12, headroom: .manual(dB: 0)))
        let out = run(chain, [input], block: 4_096)[0]
        let maxStep = zip(out, out.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(maxStep < 0.1)   // an instant +12 dB jump would step by ~0.3
    }

    @Test func metersTrackPeaksPerChannel() {
        let chain = makeChain(ChainSettings(pregainDB: -6, headroom: .manual(dB: 0)))
        _ = run(chain, [sine(100, amplitude: 0.5, frames: 8_192), sine(100, amplitude: 0.2, frames: 8_192)])
        #expect(abs(chain.probes.outputLeft.takePeak() - 0.25) < 0.01)
        #expect(abs(chain.probes.outputRight.takePeak() - 0.1) < 0.01)
        #expect(chain.probes.outputLeft.takePeak() == 0)
    }

    @Test func analyzerFindsTone() throws {
        let probes = ChainProbes(analyzer: .post)
        let chain = ProcessingChain(probes: probes)
        chain.prepare(format: AudioFormatInfo(sampleRate: 48_000, channelCount: 1), maxFrames: 4_096)
        _ = run(chain, [sine(1_000, amplitude: 0.5, frames: 8_192)])

        let points = 200
        let spectrum = try #require(SpectrumAnalyzer().analyze(probes.spectrum, sampleRate: 48_000, points: points))
        let loudest = try #require(spectrum.indices.max { spectrum[$0] < spectrum[$1] })
        let frequency = 20 * pow(1_000.0, Double(loudest) / Double(points - 1))
        #expect(abs(log2(frequency / 1_000)) < 0.1)
        #expect(abs(spectrum[loudest] - (-6.02)) < 2)
    }

    /// Below ~200 Hz a display point covers less than one FFT bin; interpolation must still
    /// find the tone at its true level.
    @Test func analyzerReadsLowTone() throws {
        let probes = ChainProbes(analyzer: .pre)
        let chain = ProcessingChain(probes: probes)
        chain.prepare(format: AudioFormatInfo(sampleRate: 48_000, channelCount: 1), maxFrames: 4_096)
        _ = run(chain, [sine(50, amplitude: 0.5, frames: 8_192)])

        let points = 400
        let spectrum = try #require(SpectrumAnalyzer().analyze(probes.spectrum, sampleRate: 48_000, points: points))
        let loudest = try #require(spectrum.indices.max { spectrum[$0] < spectrum[$1] })
        let frequency = 20 * pow(1_000.0, Double(loudest) / Double(points - 1))
        #expect(abs(log2(frequency / 50)) < 0.1)
        #expect(abs(spectrum[loudest] - (-6.02)) < 2)
    }

    @Test func analyzerOffWritesNothing() {
        let probes = ChainProbes(analyzer: .off)
        let chain = ProcessingChain(probes: probes)
        _ = run(chain, [sine(1_000, frames: 8_192)])
        #expect(SpectrumAnalyzer().analyze(probes.spectrum, sampleRate: 48_000, points: 64) == nil)
    }
}

struct ParameterMailboxTests {
    @Test func returnsNilUntilPublished() {
        let mailbox = ParameterMailbox<Double>(capacity: 4, initial: 0)
        #expect(mailbox.consume() == nil)
        [1.0, 2.0].withUnsafeBufferPointer { mailbox.publish($0) }
        #expect(Array(mailbox.consume()!) == [1, 2])
        #expect(mailbox.consume() == nil)
    }

    @Test func readerSeesLatestSnapshot() {
        let mailbox = ParameterMailbox<Double>(capacity: 2, initial: 0)
        for v in 1...5 { [Double(v)].withUnsafeBufferPointer { mailbox.publish($0) } }
        #expect(Array(mailbox.consume()!) == [5])
    }

    final class Flag: @unchecked Sendable { let done = Atomic<Bool>(false) }

    @Test func noTornReadsUnderContention() {
        let mailbox = ParameterMailbox<Double>(capacity: 64, initial: 0)
        let flag = Flag()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for i in 1...200_000 {
                let snapshot = [Double](repeating: Double(i), count: 64)
                snapshot.withUnsafeBufferPointer { mailbox.publish($0) }
            }
            flag.done.store(true, ordering: .releasing)
            group.leave()
        }

        var last = 0.0
        var torn = false
        while !flag.done.load(ordering: .acquiring) {
            guard let snapshot = mailbox.consume() else { continue }
            if snapshot.contains(where: { $0 != snapshot[0] }) || snapshot[0] < last { torn = true }
            last = snapshot[0]
        }
        group.wait()
        #expect(!torn)
    }
}
