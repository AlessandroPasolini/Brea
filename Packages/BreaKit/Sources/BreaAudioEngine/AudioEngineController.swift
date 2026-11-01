import BreaCore
import BreaDSP
import CoreAudio
import Foundation
import Observation

/// Everything the user chose about routing and processing. Persisted by the app and restored
/// at launch.
///
/// Missing keys fall back to their defaults, so files written by earlier versions keep loading;
/// unknown keys (such as the analyzer point older versions saved) are ignored. The analyzer
/// point is deliberately not here: see ``AudioEngineController/analyzer``.
public struct EngineConfiguration: Equatable, Codable, Sendable {
    public var mode: EngineMode
    /// Bundle identifiers processed in ``EngineMode/perApp`` mode.
    public var enabledApps: Set<String>
    /// Settings per session. The editor edits ``SessionKey/global``; per-app sessions use it too.
    public var settings: [SessionKey: ChainSettings]
    /// Limits processing to one output device (by UID); `nil` processes on any output.
    public var outputDeviceUID: String?
    /// The name shown for ``outputDeviceUID`` while that device is disconnected.
    public var outputDeviceName: String?

    public init(mode: EngineMode = .global, enabledApps: Set<String> = [], settings: [SessionKey: ChainSettings] = [:],
                outputDeviceUID: String? = nil, outputDeviceName: String? = nil) {
        self.mode = mode
        self.enabledApps = enabledApps
        self.settings = settings
        self.outputDeviceUID = outputDeviceUID
        self.outputDeviceName = outputDeviceName
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(EngineMode.self, forKey: .mode) ?? .global
        enabledApps = try c.decodeIfPresent(Set<String>.self, forKey: .enabledApps) ?? []
        settings = try c.decodeIfPresent([SessionKey: ChainSettings].self, forKey: .settings) ?? [:]
        outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        outputDeviceName = try c.decodeIfPresent(String.self, forKey: .outputDeviceName)
    }
}

/// The UI-facing facade of the audio engine.
///
/// ## Responsibilities
/// - Holds the ``EngineConfiguration`` and reports every user-driven change through
///   ``onConfigurationChange`` (the app persists it).
/// - Discovers applications with audio and connected output devices, and keeps both lists
///   current through Core Audio property listeners.
/// - Turns the configuration into session requests for the ``TapEngine``.
/// - Publishes the engine's ``EngineStatus`` for the UI.
///
/// ## Request flow
/// 1. A user intent (mode, selected apps, output device) or a discovery change calls
///    `pushRequests`.
/// 2. `.global` mode requests one system-wide session; `.perApp` requests one session per
///    selected app that has process objects. Every session uses the global settings.
/// 3. The engine reconciles the Core Audio objects off the main thread and reports back.
///
/// Settings edits skip step 2: ``updateSettings(_:for:)`` sends them straight to the running
/// chains, which is cheap enough to do on every drag event.
///
/// ## Threading
/// Main actor. All Core Audio object work happens on the engine's own queue.
@MainActor
@Observable
public final class AudioEngineController {
    public private(set) var apps: [AudioAppInfo] = []
    public private(set) var outputDevices: [OutputDeviceInfo] = []
    public private(set) var status = EngineStatus()
    public private(set) var configuration: EngineConfiguration
    /// Where the analyzer listens. Session state, not configuration: every launch starts at
    /// ``BreaDSP/AnalyzerPoint/off`` and changes are never saved.
    public private(set) var analyzer: AnalyzerPoint = .off

    /// Called after every user-driven configuration change.
    @ObservationIgnored public var onConfigurationChange: ((EngineConfiguration) -> Void)?

    @ObservationIgnored private let engine = TapEngine()
    @ObservationIgnored private var probes: [SessionKey: ChainProbes] = [:]
    @ObservationIgnored private var processListListener: CAPropertyListener?
    @ObservationIgnored private var deviceListListener: CAPropertyListener?
    @ObservationIgnored private var playingListeners: [AudioObjectID: CAPropertyListener] = [:]
    @ObservationIgnored private var isStarted = false

    public init(configuration: EngineConfiguration = EngineConfiguration()) {
        self.configuration = configuration
    }

    public var mode: EngineMode { configuration.mode }

    /// The current output sample rate, or 48 kHz before the first status arrives.
    public var sampleRate: Double { status.sampleRate > 0 ? status.sampleRate : 48_000 }

    /// Starts the engine, the listeners and the first discovery pass. Idempotent.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        engine.start { [weak self] status in
            Task { @MainActor in self?.status = status }
        }
        processListListener = CAPropertyListener(object: CA.system, selector: kAudioHardwarePropertyProcessObjectList,
                                                 queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.refreshApps() }
        }
        deviceListListener = CAPropertyListener(object: CA.system, selector: kAudioHardwarePropertyDevices,
                                                queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        refreshDevices()
        refreshApps()
    }

    /// Removes every tap synchronously, so applications play normally once Brea quits.
    public func shutdown() {
        processListListener = nil
        deviceListListener = nil
        playingListeners = [:]
        engine.shutdown()
        isStarted = false
    }

    // MARK: - User intents

    public func setMode(_ mode: EngineMode) {
        guard mode != configuration.mode else { return }
        configuration.mode = mode
        configurationChanged()
    }

    public func isEnabled(_ bundleID: String) -> Bool {
        configuration.enabledApps.contains(bundleID)
    }

    public func setEnabled(_ enabled: Bool, for bundleID: String) {
        if enabled { configuration.enabledApps.insert(bundleID) } else { configuration.enabledApps.remove(bundleID) }
        configurationChanged()
    }

    /// Limits processing to `device`; `nil` processes on whatever device the system uses.
    public func setOutputDevice(_ device: OutputDeviceInfo?) {
        guard device?.id != configuration.outputDeviceUID else { return }
        configuration.outputDeviceUID = device?.id
        configuration.outputDeviceName = device?.name
        configurationChanged()
    }

    /// Moves the analyzer for every session. Not reported through ``onConfigurationChange``.
    public func setAnalyzer(_ point: AnalyzerPoint) {
        guard point != analyzer else { return }
        analyzer = point
        for probe in probes.values { probe.analyzer = point }
    }

    /// The settings of `key`, or ``BreaDSP/ChainSettings/standard`` when none were saved.
    public func settings(for key: SessionKey) -> ChainSettings {
        configuration.settings[key] ?? .standard
    }

    /// Stores and applies new settings. Global settings also reach every per-app session.
    public func updateSettings(_ settings: ChainSettings, for key: SessionKey) {
        guard settings != self.settings(for: key) else { return }
        configuration.settings[key] = settings
        engine.updateSettings(settings, for: key)
        if key == .global {
            for bundleID in configuration.enabledApps { engine.updateSettings(settings, for: .app(bundleID: bundleID)) }
        }
        onConfigurationChange?(configuration)
    }

    /// The probes of every running session, or those of `key` when nothing runs.
    public func activeProbes(fallback key: SessionKey) -> [ChainProbes] {
        let running = status.activeSessions.map { probes(for: $0) }
        return running.isEmpty ? [probes(for: key)] : running
    }

    /// The meters and analyzer feed of `key`, created on first use and kept across rebuilds.
    public func probes(for key: SessionKey) -> ChainProbes {
        if let existing = probes[key] { return existing }
        let created = ChainProbes(analyzer: analyzer)
        probes[key] = created
        return created
    }

    // MARK: - Discovery and requests

    private func configurationChanged() {
        pushRequests()
        onConfigurationChange?(configuration)
    }

    private func refreshApps() {
        let current = AudioAppDiscovery.scan()
        if current != apps { apps = current }
        syncPlayingListeners()
        pushRequests()
    }

    private func refreshDevices() {
        let current = OutputDeviceInfo.connected()
        if current != outputDevices { outputDevices = current }
    }

    /// Keeps one `isRunningOutput` listener per known process object, so the app list follows
    /// processes starting and stopping playback.
    private func syncPlayingListeners() {
        let objects = Set(apps.flatMap(\.processObjects))
        for object in playingListeners.keys where !objects.contains(object) { playingListeners[object] = nil }
        for object in objects where playingListeners[object] == nil {
            playingListeners[object] = CAPropertyListener(object: object, selector: kAudioProcessPropertyIsRunningOutput,
                                                          queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.refreshApps() }
            }
        }
    }

    private func pushRequests() {
        guard isStarted else { return }
        var requests: [SessionKey: SessionRequest] = [:]
        switch configuration.mode {
        case .global:
            requests[.global] = SessionRequest(target: .global, settings: settings(for: .global), probes: probes(for: .global))
        case .perApp:
            for app in apps where configuration.enabledApps.contains(app.id) && !app.processObjects.isEmpty {
                let key = SessionKey.app(bundleID: app.id)
                requests[key] = SessionRequest(target: .app(bundleID: app.id, processes: app.processObjects),
                                               settings: settings(for: .global), probes: probes(for: key))
            }
        }
        engine.apply(requests, requiredDeviceUID: configuration.outputDeviceUID)
    }
}
