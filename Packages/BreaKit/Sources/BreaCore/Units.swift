import Foundation

/// Conversions between decibels and linear amplitude.
public enum Decibels {
    /// Linear amplitude factor for `db` decibels: `10^(db / 20)`.
    public static func toLinear(_ db: Double) -> Double { pow(10, db / 20) }
}

/// The stream format a processing chain is prepared for.
public struct AudioFormatInfo: Equatable, Sendable {
    /// Frames per second, in hertz.
    public var sampleRate: Double
    /// Interleaved or planar channel count of the stream.
    public var channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}
