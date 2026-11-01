import AppKit
import SwiftUI

/// The menu of Brea's menu bar extra, the way back to the app while it runs in the background.
///
/// | Item | Effect |
/// |---|---|
/// | Open Brea | Shows the main window (reopening it if it was closed) and brings Brea forward. |
/// | Bypass | Toggles bypass, like the board's Bypass button. |
/// | Settings… | Opens Settings. |
/// | Quit Brea | Quits; unsaved changes are offered for saving first. |
///
/// Brea is not in the Dock while its window is closed, so this menu is the way to reach it then
/// (launching it again from the Finder also reopens the window).
public struct BreaMenuBarMenu: View {
    private let model: EditorModel
    private let windowID: String
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// - Parameters:
    ///   - model: The editor, for bypass.
    ///   - windowID: The identifier of the main window scene.
    public init(model: EditorModel, windowID: String) {
        self.model = model
        self.windowID = windowID
    }

    public var body: some View {
        Button("Open Brea") {
            openWindow(id: windowID)
            NSApp.activate()
        }
        Toggle("Bypass", isOn: bypassBinding)
        Divider()
        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Brea") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var bypassBinding: Binding<Bool> {
        Binding { model.settings.isBypassed } set: { model.settingsBinding.wrappedValue.isBypassed = $0 }
    }
}
