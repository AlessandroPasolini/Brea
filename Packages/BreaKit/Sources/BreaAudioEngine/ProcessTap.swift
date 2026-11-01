import CoreAudio
import Foundation

/// What a session captures.
public enum TapTarget: Hashable, Sendable {
    /// The given process objects of one application.
    case app(bundleID: String, processes: [AudioObjectID])
    /// Everything the system plays, except Brea itself.
    case global
}

/// A muted Core Audio process tap.
struct ProcessTap {
    let id: AudioObjectID
    let uid: String
    /// Bound to the output device's stream: same clock and format as the device.
    let isStreamBound: Bool

    /// Creates the tap for `target`.
    ///
    /// ## Steps
    /// 1. Try a tap bound to stream 0 of the output device, which delivers audio in the
    ///    device's own format and clock.
    /// 2. If that fails, fall back to a stereo mixdown tap.
    /// 3. Both are private and `.muted`: while the tap exists the tapped audio never reaches the
    ///    device unprocessed, which keeps rebuilds and mode switches free of dry leaks.
    ///
    /// - Throws: ``CoreAudioError`` when neither tap can be created (usually a missing
    ///   Audio Capture permission).
    static func make(_ target: TapTarget, excluding excluded: [AudioObjectID], deviceUID: String) throws -> ProcessTap {
        let candidates: [CATapDescription] = switch target {
        case .app(_, let processes):
            [CATapDescription(processes: processes, deviceUID: deviceUID, stream: 0),
             CATapDescription(stereoMixdownOfProcesses: processes)]
        case .global:
            [CATapDescription(excludingProcesses: excluded, deviceUID: deviceUID, stream: 0),
             CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)]
        }

        var status: OSStatus = noErr
        for (index, description) in candidates.enumerated() {
            description.uuid = UUID()
            description.name = "Brea Tap"
            description.isPrivate = true
            description.muteBehavior = .muted
            var id = CA.unknown
            status = AudioHardwareCreateProcessTap(description, &id)
            if status == noErr, id != CA.unknown {
                return ProcessTap(id: id, uid: description.uuid.uuidString, isStreamBound: index == 0)
            }
        }
        throw CoreAudioError("Could not create the audio tap. Check Audio Capture permission in System Settings", status)
    }

    func destroy() {
        AudioHardwareDestroyProcessTap(id)
    }
}

/// A private aggregate device whose output is the real device and whose input is a tap.
struct AggregateDevice {
    let id: AudioObjectID

    /// Creates the aggregate for `tap` on the device `outputUID`.
    ///
    /// ## Drift compensation
    /// A stream-bound tap already runs on the device's clock, so compensation would only add a
    /// continuous resampler (audible as dulled highs); it stays off. A mixdown tap may drift, so
    /// it gets compensation at the highest resampler quality.
    static func make(outputUID: String, tap: ProcessTap) throws -> AggregateDevice {
        var tapEntry: [String: Any] = [kAudioSubTapUIDKey: tap.uid,
                                       kAudioSubTapDriftCompensationKey: !tap.isStreamBound]
        if !tap.isStreamBound {
            tapEntry[kAudioSubTapDriftCompensationQualityKey] = kAudioAggregateDriftCompensationMaxQuality
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Brea",
            kAudioAggregateDeviceUIDKey: "Brea-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [tapEntry],
        ]
        var id = CA.unknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != CA.unknown else { throw CoreAudioError("Could not create the aggregate device", status) }
        return AggregateDevice(id: id)
    }

    func destroy() {
        AudioHardwareDestroyAggregateDevice(id)
    }
}
