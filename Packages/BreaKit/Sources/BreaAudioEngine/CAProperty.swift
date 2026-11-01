import CoreAudio
import Foundation

/// A Core Audio failure with a readable message and the raw `OSStatus`.
struct CoreAudioError: LocalizedError {
    let message: String
    let status: OSStatus

    init(_ message: String, _ status: OSStatus) {
        self.message = message
        self.status = status
    }

    var errorDescription: String? { status == noErr ? message : "\(message) (OSStatus \(status))" }
}

/// Typed wrappers over the AudioObject property API.
///
/// Every read targets the main element. Reads return `nil` (or an empty array) on any error,
/// because callers treat a missing property the same as an absent object.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// A fixed-size property value; `initial` provides the storage and the type.
    static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                         initial: T) -> T? {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// A variable-length array property: asks for its size, then reads it.
    static func readArray<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                              element: T) -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [T](repeating: element, count: Int(size) / MemoryLayout<T>.stride)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &items) == noErr else { return [] }
        return Array(items.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    /// A `CFString` property, returned with +1 retain by the HAL and released here.
    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static var defaultOutputDevice: AudioObjectID? {
        read(system, kAudioHardwarePropertyDefaultOutputDevice, initial: unknown).flatMap { $0 == unknown ? nil : $0 }
    }

    static func processObjects() -> [AudioObjectID] {
        readArray(system, kAudioHardwarePropertyProcessObjectList, element: unknown)
    }

    /// The HAL process object for `pid`, if that process is a Core Audio client.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        return status == noErr && object != unknown ? object : nil
    }

    static func nominalRate(_ device: AudioObjectID) -> Double? {
        read(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)).flatMap { $0 > 0 ? $0 : nil }
    }

    static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        readArray(device, kAudioDevicePropertyStreams, scope: scope, element: AudioStreamID(0)).count
    }
}

/// A connected device with outputs, as offered in Settings ▸ Audio.
public struct OutputDeviceInfo: Identifiable, Hashable, Sendable {
    /// The device UID, stable across reconnects.
    public let id: String
    public let name: String

    /// Every connected device with at least one output stream, sorted by name. Private aggregate
    /// devices (Brea's own) are never listed by the HAL.
    static func connected() -> [OutputDeviceInfo] {
        CA.readArray(CA.system, kAudioHardwarePropertyDevices, element: CA.unknown)
            .filter { CA.streamCount($0, scope: kAudioObjectPropertyScopeOutput) > 0 }
            .compactMap { device in
                guard let uid = CA.readString(device, kAudioDevicePropertyDeviceUID) else { return nil }
                return OutputDeviceInfo(id: uid, name: CA.readString(device, kAudioObjectPropertyName) ?? uid)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// A snapshot of the system's current output device.
struct OutputDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let sampleRate: Double
    /// In an aggregate built on this device, these input streams come first; the tap's
    /// buffers follow them.
    let inputStreamCount: Int

    static func current() -> OutputDevice? {
        guard let id = CA.defaultOutputDevice, let uid = CA.readString(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return OutputDevice(id: id, uid: uid,
                            name: CA.readString(id, kAudioObjectPropertyName) ?? "Output",
                            sampleRate: CA.nominalRate(id) ?? 48_000,
                            inputStreamCount: CA.streamCount(id, scope: kAudioObjectPropertyScopeInput))
    }
}
