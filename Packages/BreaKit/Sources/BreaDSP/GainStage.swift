/// A linear gain that glides to a new value over one block, avoiding zipper noise.
///
/// ## Per block
/// 1. If both the current and the target gain are 1, do nothing (bit-transparent).
/// 2. If they are equal, multiply every sample by the target.
/// 3. Otherwise ramp linearly from `current` to `target` across the block, then adopt the target.
///
/// Audio-thread only; ``target`` is set from the chain's parameter snapshot.
public struct GainStage: Sendable {
    public var current: Float
    public var target: Float

    public init(current: Float = 1, target: Float = 1) {
        self.current = current
        self.target = target
    }

    /// Unity now and after the next block.
    public var isUnity: Bool { current == 1 && target == 1 }

    public mutating func apply(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frameCount n: Int) {
        guard n > 0, !isUnity else { return }
        if current == target {
            for ch in 0..<channelCount {
                let x = channels[ch]
                for i in 0..<n { x[i] *= target }
            }
            return
        }
        let step = (target - current) / Float(n)
        for ch in 0..<channelCount {
            let x = channels[ch]
            var g = current
            for i in 0..<n {
                g += step
                x[i] *= g
            }
        }
        current = target
    }
}
