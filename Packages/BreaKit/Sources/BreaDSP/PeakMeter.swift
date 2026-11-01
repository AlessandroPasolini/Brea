import Synchronization

/// A peak level shared between the audio thread, which records it, and the UI, which polls it.
///
/// ## How it works
/// The peak is stored as the bit pattern of a non-negative `Float`. Non-negative IEEE-754
/// floats sort the same way as their bit patterns, so "keep the larger value" becomes an
/// integer maximum done with a compare-and-swap loop. No locks are involved on either side.
public final class PeakMeter: Sendable {
    private let bits = Atomic<UInt32>(0)

    public init() {}

    /// Audio thread. Keeps the largest peak seen since the last ``takePeak()``.
    public func record(_ peak: Float) {
        let new = peak.bitPattern
        var current = bits.load(ordering: .relaxed)
        while new > current {
            let (exchanged, original) = bits.compareExchange(expected: current, desired: new, ordering: .relaxed)
            if exchanged { return }
            current = original
        }
    }

    /// UI thread. The linear peak since the previous call; resets it to zero.
    public func takePeak() -> Float {
        Float(bitPattern: bits.exchange(0, ordering: .relaxed))
    }
}
