//
//  BreaApp.swift
//  Brea
//
//  Created by Alessandro Pasolini on 17/10/26.
//

import AppKit
import BreaAudioEngine
import BreaCore
import BreaPresets
import BreaUI
import SwiftUI

/// Brea's scenes.
///
/// - **Main window**: a single window holding the Reloj board. The board has a fixed size, so
///   the window is exactly its content size, with the title bar hidden and the background
///   draggable; Window ▸ Zoom, Fill and Move & Resize are listed but stay disabled.
/// - **Menu bar**: ``BreaUI/BreaCommands``.
/// - **Menu bar extra**: ``BreaUI/BreaMenuBarMenu``, always present, so Brea stays reachable
///   while it runs in the background.
/// - **Settings** (⌘,): ``BreaUI/BreaSettingsView``.
@main
struct BreaApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Brea", id: Self.mainWindowID) {
            RootView(model: appDelegate.environment.editor)
                .onAppear { appDelegate.mainWindowDidOpen() }
                .onDisappear { appDelegate.mainWindowDidClose() }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands { BreaCommands(model: appDelegate.environment.editor) }

        MenuBarExtra {
            BreaMenuBarMenu(model: appDelegate.environment.editor, windowID: Self.mainWindowID)
        } label: {
            MenuBarIcon(appDelegate: appDelegate)
        }

        Settings {
            BreaSettingsView(controller: appDelegate.environment.controller)
        }
    }
}

/// The menu bar extra's icon. It is on screen for the app's whole life, so it also hands the
/// app delegate a way to reopen the main window (see `AppDelegate.applicationShouldHandleReopen`).
private struct MenuBarIcon: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "slider.vertical.3")
            .accessibilityLabel("Brea")
            .onAppear {
                appDelegate.openMainWindow = { openWindow(id: BreaApp.mainWindowID) }
            }
    }
}

/// Owns the app's long-lived objects and its lifecycle.
///
/// ## Running in the background
/// - The engine starts at launch and keeps processing audio whether or not the window is open.
/// - Closing the window (⌘W or the close button) does not quit: Brea leaves the Dock and the
///   app switcher and keeps running, reachable from its menu bar extra. Reopening the window
///   (from the menu bar extra, or by launching Brea again) puts it back in the Dock.
///
/// ## Quitting
/// Only Brea ▸ Quit (⌘Q) or Quit Brea in the menu bar extra quits.
/// 1. `applicationShouldTerminate` offers to save unsaved changes; Cancel keeps the app running.
/// 2. `applicationWillTerminate` removes every tap, so applications play normally again, and
///    writes pending configuration and presets.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()

    /// Opens the main window; set by the menu bar extra once the scene is up.
    var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        environment.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // With the window closed Brea may not be frontmost; bring it forward so the save
        // alert is not hidden behind other apps.
        if environment.editor.isDirty { NSApp.activate() }
        return environment.editor.confirmDiscardingChanges() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Launching Brea again while it runs in the background reopens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow?() }
        return true
    }

    // MARK: Dock presence

    func mainWindowDidOpen() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func mainWindowDidClose() {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The composition root.
///
/// ## Wiring
/// 1. ``BreaPresets/PresetLibrary`` reads `~/Library/Application Support/Brea/presets.json`.
/// 2. ``BreaAudioEngine/AudioEngineController`` starts from `configuration.json` (or defaults),
///    and every configuration change is saved back to it, debounced.
/// 3. ``BreaUI/EditorModel`` joins both for the window and the menus.
///
/// The engine starts once the app has finished launching, not at init, so previews stay fast.
final class AppEnvironment {
    let controller: AudioEngineController
    let presets: PresetLibrary
    let editor: EditorModel
    private let configurationStore = JSONFileStore<EngineConfiguration>(
        url: JSONFileStore<EngineConfiguration>.applicationSupport("configuration.json")
    )

    init() {
        presets = PresetLibrary(store: JSONFileStore(url: JSONFileStore<[EQPreset]>.applicationSupport("presets.json")))
        controller = AudioEngineController(configuration: configurationStore.load() ?? EngineConfiguration())
        editor = EditorModel(controller: controller, presets: presets)
        controller.onConfigurationChange = { [configurationStore] in configurationStore.save($0) }
    }

    func start() {
        controller.start()
    }

    func shutdown() {
        controller.shutdown()
        configurationStore.flush()
        presets.flush()
    }
}
