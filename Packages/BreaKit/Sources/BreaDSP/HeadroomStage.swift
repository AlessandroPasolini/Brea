import Foundation

/// Headroom compensation: an output trim that keeps the equalizer from clipping.
public enum HeadroomStage {
    /// The trim, never positive, that brings the loudest point of the full response
    /// (Pre-amp plus every band) down to 0 dBFS for a full-scale input.
    public static func autoHeadroomDB(pregainDB: Double, bands: [EQBand], sampleRate: Double) -> Double {
        -max(0, EQResponse(bands: bands, offsetDB: pregainDB, sampleRate: sampleRate).peakDecibels())
    }
}

/// The chain's last stage: a hard limit at ±1.0.
///
/// Every legal sample passes bit-for-bit; only overs beyond full scale, which the converter would
/// clip anyway, are clamped. It never compresses or shapes the signal, so it cannot act as a
/// hidden level normalizer.
enum ClipGuard {
    static func apply(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frameCount n: Int) {
        for ch in 0..<channelCount {
            let x = channels[ch]
            for i in 0..<n { x[i] = min(1, max(-1, x[i])) }
        }
    }
}
