/// A cascade of biquad sections in Transposed Direct Form II.
///
/// ## Precision
/// Coefficients and filter state are 64-bit; samples enter and leave as 32-bit float.
///
/// ## Per block (``process(_:channelCount:frameCount:)``)
/// For every section:
/// 1. If its current coefficients are the identity and no change is pending, clear its state
///    (so re-enabling starts clean) and skip it.
/// 2. If new target coefficients are pending, interpolate linearly from the current ones to the
///    targets across the block, sample by sample; otherwise filter with fixed coefficients.
/// 3. Flush denormal values out of the recursive state.
/// 4. Adopt the targets as current coefficients.
///
/// Finally ``isIdentity`` records whether every section is now a pass-through.
///
/// ## Threading
/// All memory is allocated in `init`. ``setTarget(_:bandCount:)``, ``reset(snapToTarget:)``
/// and `process` belong to the audio thread (or to a control thread while audio is stopped).
public final class ParametricEQ: @unchecked Sendable {
    /// Channels with their own filter state; extra channels pass through unfiltered.
    public static let maxChannels = 8

    public let maxBands: Int
    /// Five coefficients (b0 b1 b2 a1 a2) per section.
    private let current: UnsafeMutablePointer<Double>
    private let target: UnsafeMutablePointer<Double>
    /// Two state variables (z1 z2) per section and channel.
    private let state: UnsafeMutablePointer<Double>

    /// Whether every section currently passes audio through untouched.
    public private(set) var isIdentity = true

    public init(maxBands: Int) {
        self.maxBands = maxBands
        current = .allocate(capacity: maxBands * 5)
        target = .allocate(capacity: maxBands * 5)
        state = .allocate(capacity: maxBands * Self.maxChannels * 2)
        for band in 0..<maxBands {
            Self.writeIdentity(current + band * 5)
            Self.writeIdentity(target + band * 5)
        }
        state.initialize(repeating: 0, count: maxBands * Self.maxChannels * 2)
    }

    deinit {
        current.deallocate()
        target.deallocate()
        state.deallocate()
    }

    /// Sets new targets from `bandCount` consecutive (b0 b1 b2 a1 a2) groups. Sections beyond
    /// `bandCount` glide to the identity.
    public func setTarget(_ coefficients: UnsafePointer<Double>, bandCount: Int) {
        let n = min(bandCount, maxBands)
        target.update(from: coefficients, count: n * 5)
        for band in n..<maxBands { Self.writeIdentity(target + band * 5) }
    }

    /// Clears all filter state. With `snapToTarget`, coefficients jump to their targets without gliding.
    public func reset(snapToTarget: Bool) {
        state.update(repeating: 0, count: maxBands * Self.maxChannels * 2)
        if snapToTarget { current.update(from: target, count: maxBands * 5) }
        isIdentity = (0..<maxBands).allSatisfy { Self.isIdentity(current + $0 * 5) }
    }

    public func process(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frameCount n: Int) {
        let chCount = min(channelCount, Self.maxChannels)
        var allIdentity = true
        for band in 0..<maxBands {
            let cur = current + band * 5
            let tgt = target + band * 5
            let moving = Self.differs(cur, tgt)

            if Self.isIdentity(cur) && !moving {
                (state + band * Self.maxChannels * 2).update(repeating: 0, count: Self.maxChannels * 2)
                continue
            }

            for ch in 0..<chCount {
                let x = channels[ch]
                let s = state + (band * Self.maxChannels + ch) * 2
                var z1 = s[0], z2 = s[1]
                var b0 = cur[0], b1 = cur[1], b2 = cur[2], a1 = cur[3], a2 = cur[4]
                if moving {
                    let inv = 1 / Double(max(n, 1))
                    let d0 = (tgt[0] - b0) * inv, d1 = (tgt[1] - b1) * inv, d2 = (tgt[2] - b2) * inv
                    let e1 = (tgt[3] - a1) * inv, e2 = (tgt[4] - a2) * inv
                    for i in 0..<n {
                        b0 += d0; b1 += d1; b2 += d2; a1 += e1; a2 += e2
                        let xd = Double(x[i])
                        let y = b0 * xd + z1
                        z1 = b1 * xd - a1 * y + z2
                        z2 = b2 * xd - a2 * y
                        x[i] = Float(y)
                    }
                } else {
                    for i in 0..<n {
                        let xd = Double(x[i])
                        let y = b0 * xd + z1
                        z1 = b1 * xd - a1 * y + z2
                        z2 = b2 * xd - a2 * y
                        x[i] = Float(y)
                    }
                }
                s[0] = abs(z1) < 1e-30 ? 0 : z1
                s[1] = abs(z2) < 1e-30 ? 0 : z2
            }
            if moving { cur.update(from: tgt, count: 5) }
            if !Self.isIdentity(cur) { allIdentity = false }
        }
        isIdentity = allIdentity
    }

    private static func writeIdentity(_ p: UnsafeMutablePointer<Double>) {
        p[0] = 1; p[1] = 0; p[2] = 0; p[3] = 0; p[4] = 0
    }

    private static func isIdentity(_ p: UnsafeMutablePointer<Double>) -> Bool {
        p[0] == 1 && p[1] == 0 && p[2] == 0 && p[3] == 0 && p[4] == 0
    }

    private static func differs(_ a: UnsafeMutablePointer<Double>, _ b: UnsafeMutablePointer<Double>) -> Bool {
        a[0] != b[0] || a[1] != b[1] || a[2] != b[2] || a[3] != b[3] || a[4] != b[4]
    }
}
