import CoreAudio

/// Converts between the HAL's buffer lists (interleaved or not) and the planar Float32 storage
/// the DSP chain works on.
///
/// All storage is allocated once in `init`; ``gather(_:firstBuffer:)`` and
/// ``scatter(_:channelCount:frameCount:)`` are real-time safe.
final class ChannelMapper: @unchecked Sendable {
    let maxChannels: Int
    let maxFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    /// One pointer per planar channel, valid for the mapper's lifetime.
    let channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    init(maxChannels: Int, maxFrames: Int) {
        self.maxChannels = maxChannels
        self.maxFrames = maxFrames
        storage = .allocate(capacity: maxChannels * maxFrames)
        storage.initialize(repeating: 0, count: maxChannels * maxFrames)
        channels = .allocate(capacity: maxChannels)
        for ch in 0..<maxChannels { (channels + ch).initialize(to: storage + ch * maxFrames) }
    }

    deinit {
        storage.deallocate()
        channels.deallocate()
    }

    /// Copies the tap's audio into planar storage.
    ///
    /// ## Steps
    /// 1. Ignore buffers before `firstBuffer`: they are the output device's own inputs.
    /// 2. Take the frame count of the shortest remaining buffer (capped at ``maxFrames``).
    /// 3. Deinterleave each channel of each buffer into the next planar channel, up to
    ///    ``maxChannels``. A buffer without data contributes silence.
    ///
    /// - Returns: The planar channel and frame counts; `(0, 0)` when there is no tap audio.
    func gather(_ input: UnsafePointer<AudioBufferList>, firstBuffer: Int) -> (channelCount: Int, frameCount: Int) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard firstBuffer < list.count else { return (0, 0) }

        var frames = maxFrames
        var found = false
        for i in firstBuffer..<list.count {
            let k = Int(list[i].mNumberChannels)
            guard k > 0 else { continue }
            frames = min(frames, Int(list[i].mDataByteSize) / (MemoryLayout<Float>.size * k))
            found = true
        }
        guard found, frames > 0 else { return (0, 0) }

        var ch = 0
        for i in firstBuffer..<list.count {
            let buffer = list[i]
            let k = Int(buffer.mNumberChannels)
            let source = buffer.mData?.assumingMemoryBound(to: Float.self)
            for c in 0..<k where ch < maxChannels {
                let destination = channels[ch]
                if let source {
                    for f in 0..<frames { destination[f] = source[f * k + c] }
                } else {
                    destination.update(repeating: 0, count: frames)
                }
                ch += 1
            }
        }
        return (ch, frames)
    }

    /// Writes planar audio into the device's output buffers.
    ///
    /// ## Mapping
    /// - A mono source feeds every output channel.
    /// - Otherwise channels map one to one, across buffers in order.
    /// - Output channels without a source, and frames past `frameCount`, are silenced.
    func scatter(_ output: UnsafeMutablePointer<AudioBufferList>, channelCount: Int, frameCount: Int) {
        var outChannel = 0
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            let k = Int(buffer.mNumberChannels)
            guard k > 0, let destination = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                outChannel += k
                continue
            }
            let outFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * k)
            let n = min(frameCount, outFrames)
            for c in 0..<k {
                let source = channelCount == 1 ? 0 : outChannel
                if source < channelCount {
                    let s = channels[source]
                    for f in 0..<n { destination[f * k + c] = s[f] }
                    for f in n..<outFrames { destination[f * k + c] = 0 }
                } else {
                    for f in 0..<outFrames { destination[f * k + c] = 0 }
                }
                outChannel += 1
            }
        }
    }
}
