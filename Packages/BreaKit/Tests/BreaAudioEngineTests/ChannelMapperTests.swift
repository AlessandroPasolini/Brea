import CoreAudio
import Foundation
import Testing
@testable import BreaAudioEngine

/// Owns a synthetic AudioBufferList whose buffers are `[channels per buffer]` wide.
final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    let frames: Int

    init(_ layout: [Int], frames: Int, fill: (_ buffer: Int, _ frame: Int, _ channel: Int) -> Float = { _, _, _ in 0 }) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: layout.count)
        for (b, k) in layout.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * k)
            for f in 0..<frames { for c in 0..<k { data[f * k + c] = fill(b, f, c) } }
            list[b] = AudioBuffer(mNumberChannels: UInt32(k), mDataByteSize: UInt32(frames * k * 4), mData: data)
        }
    }

    func sample(buffer: Int, frame: Int, channel: Int) -> Float {
        let k = Int(list[buffer].mNumberChannels)
        return list[buffer].mData!.assumingMemoryBound(to: Float.self)[frame * k + channel]
    }

    deinit {
        for buffer in list { buffer.mData?.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

struct ChannelMapperTests {
    let mapper = ChannelMapper(maxChannels: 8, maxFrames: 1_024)

    @Test func skipsDeviceInputsAndDeinterleaves() {
        // Buffer 0: the output device's own mic (ignored). Buffer 1: interleaved stereo tap.
        let input = TestBufferList([1, 2], frames: 64) { b, f, c in b == 0 ? 99 : Float(f) + (c == 0 ? 0 : 0.5) }
        let (channels, frames) = mapper.gather(input.list.unsafePointer, firstBuffer: 1)
        #expect(channels == 2 && frames == 64)
        #expect(mapper.channels[0][10] == 10 && mapper.channels[1][10] == 10.5)

        let output = TestBufferList([2], frames: 64)
        mapper.scatter(output.list.unsafeMutablePointer, channelCount: channels, frameCount: frames)
        #expect(output.sample(buffer: 0, frame: 10, channel: 0) == 10)
        #expect(output.sample(buffer: 0, frame: 10, channel: 1) == 10.5)
    }

    @Test func monoFeedsEveryOutputChannel() {
        let input = TestBufferList([1], frames: 32) { _, f, _ in Float(f) }
        let (channels, frames) = mapper.gather(input.list.unsafePointer, firstBuffer: 0)
        let output = TestBufferList([2], frames: 32)
        mapper.scatter(output.list.unsafeMutablePointer, channelCount: channels, frameCount: frames)
        #expect(output.sample(buffer: 0, frame: 7, channel: 0) == 7)
        #expect(output.sample(buffer: 0, frame: 7, channel: 1) == 7)
    }

    @Test func nonInterleavedInputToInterleavedOutput() {
        let input = TestBufferList([1, 1], frames: 16) { b, f, _ in Float(b * 100 + f) }
        let (channels, frames) = mapper.gather(input.list.unsafePointer, firstBuffer: 0)
        #expect(channels == 2)
        let output = TestBufferList([2], frames: 16)
        mapper.scatter(output.list.unsafeMutablePointer, channelCount: channels, frameCount: frames)
        #expect(output.sample(buffer: 0, frame: 3, channel: 0) == 3)
        #expect(output.sample(buffer: 0, frame: 3, channel: 1) == 103)
    }

    @Test func silencesUnmappedChannelsAndTail() {
        let input = TestBufferList([2], frames: 16) { _, _, _ in 1 }
        let (channels, frames) = mapper.gather(input.list.unsafePointer, firstBuffer: 0)
        // Wider and longer output than the tap provides; pre-fill with garbage.
        let output = TestBufferList([4], frames: 32) { _, _, _ in 7 }
        mapper.scatter(output.list.unsafeMutablePointer, channelCount: channels, frameCount: frames)
        #expect(output.sample(buffer: 0, frame: 0, channel: 1) == 1)
        #expect(output.sample(buffer: 0, frame: 0, channel: 2) == 0)
        #expect(output.sample(buffer: 0, frame: 20, channel: 0) == 0)
    }

    @Test func missingTapBuffersProduceSilence() {
        let input = TestBufferList([1], frames: 16) { _, _, _ in 1 }
        let (channels, frames) = mapper.gather(input.list.unsafePointer, firstBuffer: 1)
        #expect(channels == 0 && frames == 0)
        let output = TestBufferList([2], frames: 16) { _, _, _ in 7 }
        mapper.scatter(output.list.unsafeMutablePointer, channelCount: channels, frameCount: frames)
        #expect(output.sample(buffer: 0, frame: 5, channel: 1) == 0)
    }
}
