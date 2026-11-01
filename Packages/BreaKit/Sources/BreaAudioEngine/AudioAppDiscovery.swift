import AppKit
import CoreAudio

/// An application that has opened audio, with every Core Audio process object playing for it.
public struct AudioAppInfo: Identifiable, Hashable, Sendable {
    /// The owning application's bundle identifier.
    public let id: String
    public let name: String
    /// HAL process objects attributed to this app (helpers included), sorted.
    public var processObjects: [AudioObjectID]
    /// Whether any of those processes is currently producing output.
    public var isPlaying: Bool
}

/// Finds the applications that can be tapped individually.
@MainActor
enum AudioAppDiscovery {
    /// Groups every HAL process object under the regular application that owns it.
    ///
    /// ## Steps
    /// 1. List the regular (Dock) applications, excluding Brea.
    /// 2. For each HAL process object, read its bundle identifier, PID and output state.
    /// 3. Attribute it to an owner with ``owner(bundle:pid:apps:)``; skip it when none matches.
    /// 4. Merge objects by owner and sort the result by name.
    ///
    /// Each process object ends up in exactly one app, so two per-app sessions never tap the
    /// same process.
    static func scan() -> [AudioAppInfo] {
        let me = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.processIdentifier != me
        }
        var groups: [String: AudioAppInfo] = [:]
        for object in CA.processObjects() {
            guard let bundle = CA.readString(object, kAudioProcessPropertyBundleID), !bundle.isEmpty,
                  let pid = CA.read(object, kAudioProcessPropertyPID, initial: pid_t(-1)), pid != me,
                  let app = owner(bundle: bundle, pid: pid, apps: apps), let key = app.bundleIdentifier else { continue }
            let playing = (CA.read(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            groups[key, default: AudioAppInfo(id: key, name: app.localizedName ?? key, processObjects: [], isPlaying: false)]
                .processObjects.append(object)
            if playing { groups[key]?.isPlaying = true }
        }
        return groups.values
            .map { var app = $0; app.processObjects.sort(); return app }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The application a process object plays for.
    ///
    /// Browsers and players often output from helper processes, so ownership is resolved in order:
    /// 1. The application with the same PID.
    /// 2. For WebKit processes (shared by every WebKit app), Safari.
    /// 3. The application whose bundle identifier is the longest prefix of the process's
    ///    (`com.google.Chrome.helper` → `com.google.Chrome`).
    private static func owner(bundle: String, pid: pid_t, apps: [NSRunningApplication]) -> NSRunningApplication? {
        if let app = apps.first(where: { $0.processIdentifier == pid }) { return app }
        if bundle.hasPrefix("com.apple.WebKit") { return apps.first { $0.bundleIdentifier == "com.apple.Safari" } }
        return apps
            .filter { app in app.bundleIdentifier.map { bundle.hasPrefix($0 + ".") } ?? false }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
    }
}
