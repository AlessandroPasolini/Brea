import BreaDSP
import Foundation
import Observation

/// Reads the chains' probes at display rate and turns them into what the meters and the
/// analyzer draw.
///
/// ## Per tick (every 33 ms, ``run(probes:sampleRate:)``)
/// 1. Ask for the probes of every running chain (one per selected app in per-app mode).
/// 2. Take each channel's peak since the last tick, keeping the loudest across chains.
/// 3. Apply meter ballistics: instant attack, 24 dB/s fall; the peak line holds 1.5 s, then
///    falls at 12 dB/s. Levels are dBFS, floored at ``floorDB``.
/// 4. Analyse the first chain's spectrum feed (``spectrumPoints`` log-spaced points, see
///    ``BreaDSP/SpectrumAnalyzer``), or clear it when the analyzer is off.
///
/// ## Performance
/// Properties are only assigned when their value changes, so silence or a disabled analyzer
/// causes no redraws. Only the views that read a property (``OutputMeters`` and the display's
/// spectrum layer) re-render on each tick, never the whole page.
@MainActor
@Observable
final class SignalMonitor {
    nonisolated static let floorDB = -60.0
    /// About one point every 2.7 pt across the display; the spline fills in between.
    nonisolated static let spectrumPoints = 384

    private(set) var left = Level()
    private(set) var right = Level()
    /// dBFS levels from 20 Hz to 20 kHz (or Nyquist); `nil` while the analyzer is off.
    private(set) var spectrum: [Float]?

    struct Level: Equatable {
        var level = SignalMonitor.floorDB
        var peak = SignalMonitor.floorDB
        var peakTime = ContinuousClock.now
    }

    @ObservationIgnored private let analyzer = SpectrumAnalyzer()

    /// Runs until the calling task is cancelled.
    func run(probes: @escaping @MainActor () -> [ChainProbes], sampleRate: @escaping @MainActor () -> Double) async {
        let clock = ContinuousClock()
        var last = clock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(33))
            let now = clock.now
            let elapsed = (now - last) / .seconds(1)
            last = now
            let all = probes()

            let nextLeft = Self.advance(left, peak: all.map { $0.outputLeft.takePeak() }.max() ?? 0, now: now, elapsed: elapsed)
            let nextRight = Self.advance(right, peak: all.map { $0.outputRight.takePeak() }.max() ?? 0, now: now, elapsed: elapsed)
            if nextLeft != left { left = nextLeft }
            if nextRight != right { right = nextRight }

            if let first = all.first, first.analyzer != .off {
                spectrum = analyzer.analyze(first.spectrum, sampleRate: sampleRate(), points: Self.spectrumPoints)
            } else if spectrum != nil {
                spectrum = nil
            }
        }
    }

    private static func advance(_ current: Level, peak linear: Float, now: ContinuousClock.Instant, elapsed: Double) -> Level {
        let input = linear > 0 ? max(floorDB, 20 * log10(Double(linear))) : floorDB
        var next = current
        next.level = max(input, current.level - 24 * elapsed)
        if input >= current.peak {
            if input > current.peak || current.peak > floorDB { next.peakTime = now }
            next.peak = input
        } else if now - current.peakTime > .milliseconds(1_500) {
            next.peak = max(floorDB, current.peak - 12 * elapsed)
        }
        return next
    }
}
