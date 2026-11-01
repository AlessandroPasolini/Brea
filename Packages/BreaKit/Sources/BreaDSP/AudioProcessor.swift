import BreaCore

/// A real-time audio stage that can be inserted into a ``ProcessingChain``.
///
/// ## Overview
/// Audio arrives as planar 32-bit float buffers (one pointer per channel) and is processed in
/// place. Future effect modules (reverb, delay…) conform to this protocol and are passed to
/// ``ProcessingChain/init(effects:probes:)``.
///
/// ## Lifecycle
/// 1. ``prepare(format:maxFrames:)`` runs on a control thread before audio starts and whenever
///    the format changes. Allocate everything here.
/// 2. ``process(_:channelCount:frameCount:)`` runs on the audio thread for every block.
/// 3. ``reset()`` clears internal state (tails, delay lines) without reallocating.
///
/// ## Real-time rules
/// `process` must never allocate, lock, log or wait, and should avoid reference counting on its
/// hot path. `prepare` is never called while `process` is running.
public protocol AudioProcessor: AnyObject, Sendable {
    func prepare(format: AudioFormatInfo, maxFrames: Int)
    func process(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frameCount: Int)
    func reset()
}
