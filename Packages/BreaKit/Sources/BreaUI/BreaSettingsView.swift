import AppKit
import BreaAudioEngine
import BreaCore
import SwiftUI

/// The appearance chosen in Settings ▸ General, stored in user defaults under ``key`` and
/// applied to every window.
public enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public static let key = "Brea.appearance"

    public var id: Self { self }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// The name and icon of an application by bundle identifier, whether or not it is running.
/// Icons are cached for the app's lifetime.
@MainActor
enum AppIdentity {
    private static var icons: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let cached = icons[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
        icons[bundleID] = icon
        return icon
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// The Settings window (⌘,).
///
/// ## General
/// Appearance: System, Light or Dark.
///
/// ## Audio
/// - **Apply EQ to**: any output, or one device. While another device is the system output,
///   audio plays untouched; Brea never changes the system output. A chosen device that is
///   disconnected stays listed as "(not connected)".
/// - **Process**: all apps (one system-wide tap) or selected apps (one tap per app, all using
///   the window's EQ). The list shows apps that have opened audio, plus selected apps that are
///   not running yet.
public struct BreaSettingsView: View {
    private let controller: AudioEngineController
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.system

    public init(controller: AudioEngineController) {
        self.controller = controller
    }

    public var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { general }
            Tab("Audio", systemImage: "hifispeaker") { audio }
        }
        .frame(width: 480)
        .preferredColorScheme(appearance.colorScheme)
    }

    private var general: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var audio: some View {
        Form {
            Section {
                Picker("Apply EQ to", selection: outputBinding) {
                    Text("Any Output").tag(String?.none)
                    Divider()
                    ForEach(controller.outputDevices) { device in
                        Text(device.id == controller.status.deviceUID ? "\(device.name) (current)" : device.name)
                            .tag(String?.some(device.id))
                    }
                    if let uid = controller.configuration.outputDeviceUID,
                       !controller.outputDevices.contains(where: { $0.id == uid }) {
                        Text("\(controller.configuration.outputDeviceName ?? uid) (not connected)").tag(String?.some(uid))
                    }
                }
            } footer: {
                Text("While another device is the system output, audio plays without the EQ. Brea never changes the system output.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Process", selection: modeBinding) {
                    Text("All apps").tag(EngineMode.global)
                    Text("Selected apps").tag(EngineMode.perApp)
                }
                .pickerStyle(.radioGroup)
                if controller.mode == .perApp {
                    if appRows.isEmpty {
                        Text("Apps appear here once they play audio.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(appRows, id: \.id) { row in
                        Toggle(isOn: enabledBinding(row.id)) {
                            HStack(spacing: 8) {
                                Image(nsImage: AppIdentity.icon(for: row.id))
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                Text(row.name)
                                if !row.isRunning {
                                    Text("not running").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } footer: {
                Text("Selected apps all use the EQ in the main window.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Apps with audio, then selected apps that have not played anything yet.
    private var appRows: [(id: String, name: String, isRunning: Bool)] {
        let present = controller.apps.map { (id: $0.id, name: $0.name, isRunning: true) }
        let known = Set(present.map(\.id))
        let waiting = controller.configuration.enabledApps.subtracting(known).sorted()
            .map { (id: $0, name: AppIdentity.name(for: $0), isRunning: false) }
        return present + waiting
    }

    private var outputBinding: Binding<String?> {
        Binding {
            controller.configuration.outputDeviceUID
        } set: { uid in
            guard let uid else { return controller.setOutputDevice(nil) }
            if let device = controller.outputDevices.first(where: { $0.id == uid }) { controller.setOutputDevice(device) }
        }
    }

    private var modeBinding: Binding<EngineMode> {
        Binding { controller.mode } set: { controller.setMode($0) }
    }

    private func enabledBinding(_ bundleID: String) -> Binding<Bool> {
        Binding { controller.isEnabled(bundleID) } set: { controller.setEnabled($0, for: bundleID) }
    }
}
