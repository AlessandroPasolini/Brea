import BreaCore
import BreaDSP
import CoreAudio
import Synchronization

/// Everything the IO callback touches, kept apart from the session so the callback never
/// retains or mutates session state.
///
/// ## Per IO cycle (``render(input:output:)``, HAL IO thread)
/// 1. Gather the tap's buffers into planar storage.
/// 2. Run the ``BreaDSP/ProcessingChain`` in place.
/// 3. Apply the session fade, gliding to the latest target set by ``setFade(_:)``.
/// 4. Scatter the result into the device's output buffers (silence when there was no input).
final class RenderContext: @unchecked Sendable {
    let mapper = ChannelMapper(maxChannels: ParametricEQ.maxChannels, maxFrames: 16_384)
    let chain: ProcessingChain
    /// Index of the first input buffer that belongs to the tap.
    let firstTapBuffer: Int
    private let fadeTarget: Atomic<UInt32>
    private var fade: GainStage

    init(chain: ProcessingChain, firstTapBuffer: Int, startGain: Float) {
        self.chain = chain
        self.firstTapBuffer = firstTapBuffer
        fadeTarget = Atomic(startGain.bitPattern)
        fade = GainStage(current: startGain, target: startGain)
    }

    /// Any thread. The fade glides to `gain` over the next IO block.
    func setFade(_ gain: Float) {
        fadeTarget.store(gain.bitPattern, ordering: .relaxed)
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let (channelCount, frameCount) = mapper.gather(input, firstBuffer: firstTapBuffer)
        if channelCount > 0 {
            chain.process(mapper.channels, channelCount: channelCount, frameCount: frameCount)
            fade.target = Float(bitPattern: fadeTarget.load(ordering: .relaxed))
            fade.apply(mapper.channels, channelCount: channelCount, frameCount: frameCount)
        }
        mapper.scatter(output, channelCount: channelCount, frameCount: frameCount)
    }
}

/// One running signal path: tap → private aggregate (tap + real output) → IO callback running a
/// ``BreaDSP/ProcessingChain`` → the real output.
///
/// ## Startup (`init`)
/// 1. Create the muted ``ProcessTap`` for the target.
/// 2. Create the ``AggregateDevice`` that combines the output device and the tap.
/// 3. Read the aggregate's sample rate and the tap's channel count.
/// 4. Configure and prepare the chain, then build its ``RenderContext`` starting silent.
/// 5. Register the IO callback and start the aggregate.
/// If any step fails, everything created so far is destroyed and the error is rethrown.
///
/// ## Teardown (``stop()``)
/// Stop IO → destroy the IO callback → destroy the aggregate → destroy the tap. Idempotent;
/// also runs on deallocation.
///
/// ## Threading
/// Created, faded and stopped on the engine queue only.
final class TapSession: @unchecked Sendable {
    let target: TapTarget
    let excluded: [AudioObjectID]
    let device: OutputDevice
    let chain: ProcessingChain

    private var tap: ProcessTap?
    private var aggregate: AggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var context: RenderContext?

    /// Starts silent; call ``setFade(_:)`` with 1 to bring it in.
    init(target: TapTarget, excluding excluded: [AudioObjectID], device: OutputDevice,
         settings: ChainSettings, probes: ChainProbes) throws {
        self.target = target
        self.excluded = excluded
        self.device = device
        chain = ProcessingChain(probes: probes)

        do {
            let tap = try ProcessTap.make(target, excluding: excluded, deviceUID: device.uid)
            self.tap = tap
            let aggregate = try AggregateDevice.make(outputUID: device.uid, tap: tap)
            self.aggregate = aggregate

            let sampleRate = CA.nominalRate(aggregate.id) ?? device.sampleRate
            let tapFormat = CA.read(tap.id, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            let channelCount = max(1, Int(tapFormat?.mChannelsPerFrame ?? 2))
            chain.update(settings)
            let context = RenderContext(chain: chain, firstTapBuffer: device.inputStreamCount, startGain: 0)
            chain.prepare(format: AudioFormatInfo(sampleRate: sampleRate, channelCount: channelCount),
                          maxFrames: context.mapper.maxFrames)
            self.context = context

            var procID: AudioDeviceIOProcID?
            var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.id, nil) { _, input, _, output, _ in
                context.render(input: input, output: output)
            }
            guard status == noErr, let procID else { throw CoreAudioError("Could not create the audio callback", status) }
            ioProcID = procID
            status = AudioDeviceStart(aggregate.id, procID)
            guard status == noErr else { throw CoreAudioError("Could not start audio", status) }
        } catch {
            stop()
            throw error
        }
    }

    func setFade(_ gain: Float) {
        context?.setFade(gain)
    }

    func stop() {
        if let aggregate {
            if let ioProcID {
                AudioDeviceStop(aggregate.id, ioProcID)
                AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
            }
            aggregate.destroy()
        }
        tap?.destroy()
        ioProcID = nil
        aggregate = nil
        tap = nil
        context = nil
    }

    /// Whether this session already implements `target` on `device`. The global tap must also
    /// exclude the same processes (Brea's process object may appear after the first session).
    func matches(_ target: TapTarget, excluding excluded: [AudioObjectID], device: OutputDevice) -> Bool {
        self.target == target && self.device == device && (target != .global || self.excluded == excluded)
    }

    deinit { stop() }
}
