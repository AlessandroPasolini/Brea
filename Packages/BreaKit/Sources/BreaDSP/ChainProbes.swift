import Synchronization

/// Where in the chain the spectrum analyzer listens.
public enum AnalyzerPoint: String, Codable, CaseIterable, Sendable {
    /// Before the equalizer: the source as it arrives.
    case pre
    /// After the equalizer: what is heard.
    case post
    /// No analysis; the audio thread writes nothing.
    case off
}

/// A lock-free ring buffer holding the most recent mono samples of a chain.
///
/// ## Data flow
/// 1. The audio thread calls ``write(_:channelCount:frameCount:)`` with each block. The block is
///    folded to mono (channel average) and stored at the write position.
/// 2. The position counter is published with release ordering.
/// 3. The UI calls ``readLatest(into:count:)``, which reads the counter with acquire ordering
///    and copies the newest `count` samples, oldest first.
///
/// A read that overlaps a write may mix two neighbouring blocks. That is harmless for a
/// display and keeps the audio thread wait-free.
public final class SpectrumTap: @unchecked Sendable {
    /// Buffer length, a power of two.
    public let capacity: Int
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)

    /// - Parameter capacity: Minimum length; rounded up to a power of two.
    public init(capacity: Int = 8_192) {
        var size = 1
        while size < capacity { size <<= 1 }
        self.capacity = size
        mask = size - 1
        buffer = .allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
    }

    deinit { buffer.deallocate() }

    /// Total samples written so far. An unchanged value between two reads means no audio flows.
    public var sampleCount: Int { written.load(ordering: .acquiring) }

    /// Audio thread. Appends the channel average of one block.
    func write(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frameCount n: Int) {
        guard channelCount > 0 else { return }
        let start = written.load(ordering: .relaxed)
        let scale = 1 / Float(channelCount)
        for i in 0..<n {
            var sum: Float = 0
            for ch in 0..<channelCount { sum += channels[ch][i] }
            buffer[(start + i) & mask] = sum * scale
        }
        written.store(start + n, ordering: .releasing)
    }

    /// Any thread. Copies the newest `count` samples into `destination`, oldest first.
    /// - Returns: `false` until at least `count` samples have been written.
    public func readLatest(into destination: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        let end = written.load(ordering: .acquiring)
        guard count <= capacity, end >= count else { return false }
        for i in 0..<count { destination[i] = buffer[(end - count + i) & mask] }
        return true
    }
}

/// Everything the UI observes from a running chain: output peaks per side and the analyzer feed.
///
/// ## Ownership
/// Probes belong to a ``BreaCore/SessionKey``, not to a chain. Each new chain built for that key
/// receives the same probes, so meters and the analyzer keep working across rebuilds (device or
/// sample-rate changes).
public final class ChainProbes: Sendable {
    public let outputLeft = PeakMeter()
    public let outputRight = PeakMeter()
    public let spectrum = SpectrumTap()
    private let point = Atomic<UInt8>(0)

    public init(analyzer: AnalyzerPoint = .off) {
        self.analyzer = analyzer
    }

    /// Where the analyzer listens. Readable and writable from any thread.
    public var analyzer: AnalyzerPoint {
        get {
            switch point.load(ordering: .relaxed) {
            case 1: .pre
            case 2: .post
            default: .off
            }
        }
        set {
            let raw: UInt8 = switch newValue {
            case .off: 0
            case .pre: 1
            case .post: 2
            }
            point.store(raw, ordering: .relaxed)
        }
    }

    var isAnalyzingPre: Bool { point.load(ordering: .relaxed) == 1 }
    var isAnalyzingPost: Bool { point.load(ordering: .relaxed) == 2 }
}
