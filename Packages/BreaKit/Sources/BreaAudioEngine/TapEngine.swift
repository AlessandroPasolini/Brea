import BreaCore
import BreaDSP
import CoreAudio
import Foundation

/// What the engine reports to the UI after every reconciliation.
public struct EngineStatus: Equatable, Sendable {
    public var deviceName = "—"
    public var deviceUID: String?
    public var sampleRate = 0.0
    /// Sessions currently processing audio.
    public var activeSessions: Set<SessionKey> = []
    /// Sessions that failed to start, with a readable reason.
    public var errors: [SessionKey: String] = [:]
    /// Processing is limited to another output device, so nothing runs right now.
    public var isWaitingForDevice = false
    /// A problem not tied to a session, such as having no output device.
    public var message: String?

    public init() {}
}

/// A session the controller wants running.
struct SessionRequest: Sendable {
    let target: TapTarget
    let settings: ChainSettings
    let probes: ChainProbes
}

/// Owns every Core Audio object Brea creates.
///
/// ## Model
/// The engine is declarative: ``apply(_:requiredDeviceUID:)`` states which sessions should exist
/// and `reconcile` makes the hardware match. It reconciles again whenever the default output
/// device or its sample rate changes.
///
/// ## Reconciliation
/// 1. Read the current output device. Without one, stop everything and report it.
/// 2. If processing is limited to another device, stop everything: audio plays untouched.
/// 3. Resolve Brea's own process object, which the global tap always excludes.
/// 4. For every requested session that is missing or out of date (target, device or exclusion
///    changed), build a new ``TapSession``. New sessions start silent.
/// 5. Mark sessions that were replaced or are no longer requested as retired.
/// 6. Crossfade: retired sessions fade out while new ones fade in over one IO block; after
///    60 ms the retired ones are destroyed. Taps are muted, so the switch never lets dry audio
///    through and never doubles it.
/// 7. Publish an ``EngineStatus``.
///
/// ## Threading
/// Every call hops onto one serial queue, because HAL calls block and must not run on the main
/// thread. ``shutdown()`` is synchronous so quitting can wait for the taps to be gone.
final class TapEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Brea.engine", qos: .userInitiated)
    private var statusHandler: (@Sendable (EngineStatus) -> Void)?
    private var desired: [SessionKey: SessionRequest] = [:]
    private var requiredDeviceUID: String?
    private var settings: [SessionKey: ChainSettings] = [:]
    private var sessions: [SessionKey: TapSession] = [:]
    private var errors: [SessionKey: String] = [:]
    private var message: String?
    private var device: OutputDevice?
    private var deviceListener: CAPropertyListener?
    private var rateListener: CAPropertyListener?

    private static let crossfadeMicroseconds: useconds_t = 60_000

    func start(statusHandler: @escaping @Sendable (EngineStatus) -> Void) {
        queue.async {
            self.statusHandler = statusHandler
            self.installDeviceListener()
            self.reconcile()
        }
    }

    private func installDeviceListener() {
        deviceListener = CAPropertyListener(object: CA.system, selector: kAudioHardwarePropertyDefaultOutputDevice,
                                            queue: queue) { [weak self] in self?.reconcile() }
    }

    /// Sets the sessions that should exist. `requiredDeviceUID` limits processing to one device.
    func apply(_ requests: [SessionKey: SessionRequest], requiredDeviceUID: String?) {
        queue.async {
            self.desired = requests
            self.requiredDeviceUID = requiredDeviceUID
            for (key, request) in requests { self.settings[key] = request.settings }
            self.reconcile()
        }
    }

    /// Sends new settings to a running session without rebuilding anything.
    func updateSettings(_ newSettings: ChainSettings, for key: SessionKey) {
        queue.async {
            self.settings[key] = newSettings
            self.sessions[key]?.chain.update(newSettings)
        }
    }

    /// Destroys every session and returns once all taps are gone.
    func shutdown() {
        queue.sync {
            deviceListener = nil
            rateListener = nil
            desired = [:]
            stopAll()
        }
    }

    // MARK: - Engine queue

    private func reconcile() {
        refreshDevice()
        guard let device else {
            message = "No output device"
            stopAll()
            publish()
            return
        }
        message = nil

        if let requiredDeviceUID, requiredDeviceUID != device.uid {
            stopAll()
            errors = [:]
            publish()
            return
        }

        let excluded = CA.processObject(pid: getpid()).map { [$0] } ?? []

        var created: [TapSession] = []
        var retired: [TapSession] = []
        for (key, request) in desired {
            if let current = sessions[key], current.matches(request.target, excluding: excluded, device: device) { continue }
            do {
                let session = try TapSession(target: request.target, excluding: excluded, device: device,
                                             settings: settings[key] ?? request.settings, probes: request.probes)
                if let old = sessions[key] { retired.append(old) }
                sessions[key] = session
                created.append(session)
                errors[key] = nil
            } catch {
                errors[key] = error.localizedDescription
            }
        }
        for key in sessions.keys where desired[key] == nil {
            if let old = sessions.removeValue(forKey: key) { retired.append(old) }
        }
        errors = errors.filter { desired[$0.key] != nil }

        for session in retired { session.setFade(0) }
        for session in created { session.setFade(1) }
        if !retired.isEmpty {
            usleep(Self.crossfadeMicroseconds)
            for session in retired { session.stop() }
        }
        publish()
    }

    private func stopAll() {
        for session in sessions.values { session.stop() }
        sessions = [:]
    }

    /// Reads the default output device and re-arms the sample-rate listener when it changed.
    private func refreshDevice() {
        let current = OutputDevice.current()
        if current?.id != device?.id {
            rateListener = current.flatMap {
                CAPropertyListener(object: $0.id, selector: kAudioDevicePropertyNominalSampleRate,
                                   queue: queue) { [weak self] in self?.reconcile() }
            }
        }
        device = current
    }

    private func publish() {
        var status = EngineStatus()
        status.deviceName = device?.name ?? "—"
        status.deviceUID = device?.uid
        status.sampleRate = device?.sampleRate ?? 0
        status.activeSessions = Set(sessions.keys)
        status.errors = errors
        status.isWaitingForDevice = device != nil && requiredDeviceUID != nil && requiredDeviceUID != device?.uid
        status.message = message
        statusHandler?(status)
    }
}
