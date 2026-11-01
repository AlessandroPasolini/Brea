import BreaDSP
import Foundation

/// Approximates an arbitrary magnitude curve (GraphicEQ points) with a few parametric bands.
///
/// ## Algorithm
/// 1. Resample the target on 256 log-spaced points from 20 Hz to 20 kHz (linear in dB over
///    log frequency, flat beyond the outermost points).
/// 2. Move the curve's mean level out as an offset, best expressed as pre-amp.
/// 3. Greedy loop, while bands remain and the worst error exceeds the tolerance:
///    1. Find the grid point with the largest residual error.
///    2. Add a band there, sized by where the error falls to half: a shelf when that span
///       touches either end of the grid, a peak otherwise.
///    3. Refine every band four times: a damped (×0.8) gain correction at its centre, then a
///       ×0.8 / ×1.25 Q search on peaks that keeps whatever lowers the RMS error.
/// 4. Report the largest remaining deviation so the importer can warn about it.
///
/// Gains stay within ±24 dB and Qs within 0.3…10.
public enum GraphicEQFitter {
    public struct Result: Sendable {
        public var bands: [EQBand]
        /// The curve's overall level, best expressed as pre-amp.
        public var offsetDB: Double
        /// The largest deviation from the target across 20 Hz–20 kHz.
        public var maxErrorDB: Double
    }

    /// - Parameters:
    ///   - points: (frequency Hz, gain dB) pairs, in any order.
    ///   - maxBands: The most bands to produce.
    ///   - toleranceDB: Stops once every grid point is within this error.
    public static func fit(_ points: [(frequency: Double, gainDB: Double)], maxBands: Int,
                           toleranceDB: Double = 0.25, sampleRate: Double = 48_000) -> Result {
        let grid = (0..<256).map { 20 * pow(1_000.0, Double($0) / 255) }
        let sorted = points.filter { $0.frequency > 0 }.sorted { $0.frequency < $1.frequency }
        guard !sorted.isEmpty else { return Result(bands: [], offsetDB: 0, maxErrorDB: 0) }

        let target = grid.map { interpolate(sorted, at: $0) }
        let offset = target.reduce(0, +) / Double(target.count)
        let shape = target.map { $0 - offset }

        var bands: [EQBand] = []
        func residual(_ bands: [EQBand]) -> [Double] {
            let response = EQResponse(bands: bands, sampleRate: sampleRate)
            return zip(shape, grid).map { $0 - response.decibels(at: $1) }
        }
        func rms(_ values: [Double]) -> Double {
            (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
        }

        while bands.count < maxBands {
            let r = residual(bands)
            guard let worst = r.indices.max(by: { abs(r[$0]) < abs(r[$1]) }), abs(r[worst]) > toleranceDB else { break }
            bands.append(band(for: r, around: worst, grid: grid))

            for _ in 0..<4 {
                for i in bands.indices {
                    let center = nearestIndex(of: bands[i].frequency, in: grid)
                    bands[i].gainDB = min(24, max(-24, bands[i].gainDB + 0.8 * residual(bands)[center]))
                }
                for i in bands.indices where bands[i].type == .peak {
                    var best = rms(residual(bands))
                    for factor in [0.8, 1.25] {
                        var trial = bands
                        trial[i].q = min(10, max(0.3, trial[i].q * factor))
                        let error = rms(residual(trial))
                        if error < best { best = error; bands = trial }
                    }
                }
            }
        }

        let maxError = residual(bands).map(abs).max() ?? 0
        return Result(bands: bands, offsetDB: offset, maxErrorDB: maxError)
    }

    /// The band that best covers the error around `index` (step 3.2). A peak's Q comes from
    /// the error's width in octaves N: `Q = 2^(N/2) / (2^N − 1)`.
    private static func band(for r: [Double], around index: Int, grid: [Double]) -> EQBand {
        let gain = r[index]
        var low = index, high = index
        while low > 0, r[low - 1] * gain > 0, abs(r[low - 1]) > abs(gain) / 2 { low -= 1 }
        while high < r.count - 1, r[high + 1] * gain > 0, abs(r[high + 1]) > abs(gain) / 2 { high += 1 }

        if low == 0 {
            return EQBand(type: .lowShelf, frequency: grid[high], gainDB: gain, q: 0.7071)
        }
        if high == r.count - 1 {
            return EQBand(type: .highShelf, frequency: grid[low], gainDB: gain, q: 0.7071)
        }
        let octaves = max(0.1, log2(grid[high] / grid[low]))
        let q = pow(2, octaves / 2) / (pow(2, octaves) - 1)
        return EQBand(type: .peak, frequency: grid[index], gainDB: gain, q: min(10, max(0.3, q)))
    }

    private static func interpolate(_ points: [(frequency: Double, gainDB: Double)], at f: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if f <= first.frequency { return first.gainDB }
        if f >= last.frequency { return last.gainDB }
        guard let upper = points.firstIndex(where: { $0.frequency >= f }), upper > 0 else { return first.gainDB }
        let a = points[upper - 1], b = points[upper]
        let t = log(f / a.frequency) / log(b.frequency / a.frequency)
        return a.gainDB + t * (b.gainDB - a.gainDB)
    }

    /// The grid is log-spaced, so the nearest index is a direct computation.
    private static func nearestIndex(of f: Double, in grid: [Double]) -> Int {
        let position = log(f / 20) / log(1_000) * Double(grid.count - 1)
        return min(grid.count - 1, max(0, Int(position.rounded())))
    }
}
