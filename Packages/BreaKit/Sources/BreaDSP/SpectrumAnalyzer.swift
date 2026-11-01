import Accelerate
import Foundation

/// Turns a ``SpectrumTap`` into a smoothed, log-frequency spectrum in dBFS.
///
/// ## Per call (``analyze(_:sampleRate:points:)``)
/// 1. If no audio arrived since the last call, let the previous levels fall at the release rate
///    and return them, so a stopped stream fades instead of freezing.
/// 2. Copy the newest `fftSize` samples (8192 by default: 5.9 Hz bins at 48 kHz) and apply a
///    4-term Blackman-Harris window, whose −92 dB side lobes keep loud lows from leaking over
///    quiet highs.
/// 3. Run a real FFT (vDSP) and compute the power of every bin.
/// 4. Map the linear bins onto `points` log-spaced frequencies between 20 Hz and 20 kHz (or
///    Nyquist). Each point covers a band of ``smoothingOctaves`` around its frequency:
///    - **Highs** (many bins per band): the band's power is summed, with the edge bins weighted
///      by how much of them falls inside, and divided by the window's equivalent noise
///      bandwidth. A sine then reads its true level and pink noise reads flat.
///    - **Lows** (less than a bin per band): the power is interpolated between the two
///      neighbouring bins, so the sparse low bins become a smooth curve instead of steps.
///    A point takes whichever of the two is larger, which keeps the transition seamless.
/// 5. Convert to dBFS: `vDSP_fft_zrip` returns twice the DFT, so a sine of amplitude A peaks at
///    A·Σw; dividing by the window sum makes a full-scale sine read 0 dBFS.
/// 6. Smooth over time: rises move ``attack`` of the way to the new level each call, falls are
///    limited to ``releaseDB`` per call. The first analysis is taken as is.
///
/// Runs on the UI thread; nothing here is real-time.
public final class SpectrumAnalyzer {
    public let fftSize: Int
    /// The lowest level reported.
    public static let floorDB: Float = -100
    /// Width of the band each display point averages, in octaves.
    public static let smoothingOctaves = 1.0 / 6
    /// Fraction of a rise applied per call.
    public static let attack: Float = 0.6
    /// Largest fall per call, in dB.
    public static let releaseDB: Float = 2

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    /// 20·log10 of the window sum: subtracting it normalizes a sine's peak to its amplitude.
    private let windowGainDB: Float
    /// Equivalent noise bandwidth of the window, in bins (about 2.0 for Blackman-Harris).
    private let noiseBandwidth: Float
    private var samples: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private var smoothed: [Float] = []
    private var lastSampleCount = -1

    /// - Parameter fftSize: Rounded to a power of two, at least 256. Must not exceed the tap's
    ///   capacity.
    public init(fftSize: Int = 8_192) {
        let exponent = max(8, Int(log2(Double(fftSize)).rounded()))
        let n = 1 << exponent
        self.fftSize = n
        log2n = vDSP_Length(exponent)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { fatalError("vDSP FFT setup failed") }
        self.setup = setup
        let window = Self.blackmanHarris(count: n)
        self.window = window
        let sum = window.reduce(0, +)
        let sumOfSquares = window.reduce(0) { $0 + $1 * $1 }
        windowGainDB = 20 * log10(sum)
        noiseBandwidth = Float(n) * sumOfSquares / (sum * sum)
        samples = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        power = [Float](repeating: 0, count: n / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// The periodic 4-term Blackman-Harris window.
    static func blackmanHarris(count n: Int) -> [Float] {
        let a0 = 0.35875, a1 = 0.48829, a2 = 0.14128, a3 = 0.01168
        return (0..<n).map { i in
            let x = 2 * Double.pi * Double(i) / Double(n)
            return Float(a0 - a1 * cos(x) + a2 * cos(2 * x) - a3 * cos(3 * x))
        }
    }

    /// Levels for `points` log-spaced frequencies; `nil` until the tap holds enough audio.
    public func analyze(_ tap: SpectrumTap, sampleRate: Double, points: Int) -> [Float]? {
        let count = tap.sampleCount
        if count == lastSampleCount, smoothed.count == points {
            for i in smoothed.indices { smoothed[i] = max(Self.floorDB, smoothed[i] - Self.releaseDB) }
            return smoothed
        }
        lastSampleCount = count

        let n = fftSize
        let ready = samples.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress.map { tap.readLatest(into: $0, count: n) } ?? false
        }
        guard ready, points > 1 else { return nil }
        vDSP.multiply(samples, window, result: &samples)

        real.withUnsafeMutableBufferPointer { realBuffer in
            imag.withUnsafeMutableBufferPointer { imagBuffer in
                guard let realBase = realBuffer.baseAddress, let imagBase = imagBuffer.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                samples.withUnsafeBufferPointer { input in
                    input.baseAddress?.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                imagBase[0] = 0
                power.withUnsafeMutableBufferPointer { out in
                    if let outBase = out.baseAddress { vDSP_zvmags(&split, 1, outBase, 1, vDSP_Length(n / 2)) }
                }
            }
        }

        let binWidth = sampleRate / Double(n)
        let ratio = min(20_000, sampleRate / 2) / 20
        let halfBand = pow(2, Self.smoothingOctaves / 2)
        let isFirst = smoothed.count != points
        if isFirst { smoothed = [Float](repeating: Self.floorDB, count: points) }

        for i in 0..<points {
            let centre = 20 * pow(ratio, Double(i) / Double(points - 1)) / binWidth
            let banded = bandPower(from: centre / halfBand, to: centre * halfBand) / noiseBandwidth
            let level = max(Self.floorDB, 10 * log10(max(banded, interpolatedPower(at: centre), 1e-20)) - windowGainDB)
            let previous = smoothed[i]
            smoothed[i] = isFirst ? level : level > previous ? previous + (level - previous) * Self.attack : max(level, previous - Self.releaseDB)
        }
        return smoothed
    }

    /// The power summed over the fractional bin range `low...high`; edge bins count by overlap.
    private func bandPower(from low: Double, to high: Double) -> Float {
        let last = Double(power.count - 1)
        let low = min(max(low, 1), last), high = min(max(high, 1), last)
        guard high > low else { return 0 }
        var sum: Float = 0
        var bin = Int(low.rounded())
        while Double(bin) - 0.5 < high {
            let overlap = min(high, Double(bin) + 0.5) - max(low, Double(bin) - 0.5)
            if overlap > 0, bin < power.count { sum += power[bin] * Float(overlap) }
            bin += 1
        }
        return sum
    }

    /// The power at a fractional bin, linearly interpolated between its neighbours.
    private func interpolatedPower(at position: Double) -> Float {
        let clamped = min(max(position, 1), Double(power.count - 2))
        let index = Int(clamped)
        let t = Float(clamped - Double(index))
        return power[index] * (1 - t) + power[index + 1] * t
    }
}
