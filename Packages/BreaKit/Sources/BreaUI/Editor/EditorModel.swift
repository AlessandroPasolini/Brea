import AppKit
import BreaAudioEngine
import BreaCore
import BreaDSP
import BreaPresets
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The window's equalizer as a document. Menu commands and the editor both act through it.
///
/// ## State
/// - The settings themselves live in the engine (``BreaAudioEngine/AudioEngineController``), so
///   every edit is heard immediately; this model reads and writes them for ``SessionKey/global``.
/// - The current file (`documentURL`), recent files and the text of the last saved state persist
///   in user defaults, so relaunching restores the same document and its edited state.
/// - Unsaved changes are any difference between the current settings exported as Equalizer APO
///   text and the last saved text.
///
/// ## Document commands
/// | Command | Effect |
/// |---|---|
/// | New | Offers to save, then closes the file and starts from the default EQ. |
/// | Open… / Open Recent | Offers to save, then makes the file current. History restarts. |
/// | Save / Save As… | Writes the current file (asks where when untitled). |
/// | Import… | Loads a file's EQ as one undoable step; the current file stays the same. |
/// | Export… | Writes a copy; the current file stays the same. |
/// | Presets | Saved locally under a name; loading one is an undoable step. |
///
/// Bypass is a listening state, not part of the document: opening, importing or loading keeps it.
/// Files are Equalizer APO text, readable on other computers; presets stay on this Mac.
@MainActor
@Observable
public final class EditorModel {
    public let controller: AudioEngineController
    public let presets: PresetLibrary
    public let key: SessionKey = .global

    /// The file the EQ was opened from or last saved to; `nil` while untitled.
    public private(set) var documentURL: URL?
    public private(set) var recentURLs: [URL] = []

    /// The APO text of the last saved or opened state; unsaved changes are any difference from it.
    private var savedText: String
    @ObservationIgnored let history = EditHistory()
    /// The window's undo manager, set by the editor when it appears.
    @ObservationIgnored weak var undoManager: UndoManager?

    private enum DefaultsKey {
        static let documentPath = "Brea.documentPath"
        static let savedText = "Brea.documentSavedText"
        static let recentPaths = "Brea.recentDocumentPaths"
    }

    private static let maximumRecentCount = 10

    public init(controller: AudioEngineController, presets: PresetLibrary) {
        self.controller = controller
        self.presets = presets
        let defaults = UserDefaults.standard
        documentURL = defaults.string(forKey: DefaultsKey.documentPath).map { URL(fileURLWithPath: $0) }
        savedText = defaults.string(forKey: DefaultsKey.savedText) ?? EqualizerAPOExporter.export(.standard)
        recentURLs = (defaults.stringArray(forKey: DefaultsKey.recentPaths) ?? []).map { URL(fileURLWithPath: $0) }
    }

    // MARK: Settings

    public var settings: ChainSettings { controller.settings(for: key) }

    /// Applies new settings to the engine. Every edit goes through here; with Auto-gain on, the
    /// pre-amp is recomputed so the curve's highest point lands at 0 dB.
    func setSettings(_ newValue: ChainSettings) {
        var next = newValue
        if next.isAutoPregain { next.pregainDB = next.compensatingPregainDB(sampleRate: controller.sampleRate) }
        controller.updateSettings(next, for: key)
    }

    var settingsBinding: Binding<ChainSettings> {
        Binding { [unowned self] in settings } set: { [unowned self] in setSettings($0) }
    }

    /// Records the changes since the last commit as one undo step.
    func commit(_ actionName: String) {
        history.commit(settings, actionName: actionName, undoManager: undoManager) { [weak self] restored in
            self?.controller.updateSettings(restored, for: self?.key ?? .global)
        }
    }

    /// Replaces the EQ as one undoable step, keeping bypass.
    func replace(with newSettings: ChainSettings, actionName: String) {
        var next = newSettings
        next.isBypassed = settings.isBypassed
        setSettings(next)
        commit(actionName)
    }

    /// Starts a new history from the current state (after New and Open).
    private func resetHistory() {
        undoManager?.removeAllActions()
        history.reset(to: settings)
    }

    // MARK: Document state

    public var isDirty: Bool { EqualizerAPOExporter.export(settings) != savedText }

    public var displayName: String {
        documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    private func markSaved(at url: URL?) {
        documentURL = url
        savedText = EqualizerAPOExporter.export(settings)
        let defaults = UserDefaults.standard
        defaults.set(url?.path, forKey: DefaultsKey.documentPath)
        defaults.set(savedText, forKey: DefaultsKey.savedText)
        if let url { noteRecent(url) }
    }

    private func noteRecent(_ url: URL) {
        recentURLs.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recentURLs.insert(url, at: 0)
        recentURLs = Array(recentURLs.prefix(Self.maximumRecentCount))
        UserDefaults.standard.set(recentURLs.map(\.path), forKey: DefaultsKey.recentPaths)
    }

    public func clearRecents() {
        recentURLs = []
        UserDefaults.standard.removeObject(forKey: DefaultsKey.recentPaths)
    }

    /// Offers to save unsaved changes (Save / Don’t Save / Cancel).
    ///
    /// - Returns: `true` when it is fine to go on: nothing to save, saved, or discarded.
    public func confirmDiscardingChanges() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    // MARK: File commands

    /// Closes the current file and starts from the default EQ: eight flat bells at their default
    /// frequencies, pre-amp 0 dB, Auto-gain and Headroom compensation off.
    public func newDocument() {
        guard confirmDiscardingChanges() else { return }
        var fresh = ChainSettings.standard
        fresh.bands = fresh.bands.indices.map { ChainSettings.defaultBand(at: $0) }
        fresh.isBypassed = settings.isBypassed
        setSettings(fresh)
        markSaved(at: nil)
        resetHistory()
    }

    public func openDocument() {
        guard confirmDiscardingChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Open an Equalizer APO file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, confirmed: true)
    }

    /// Opens `url` as the current file (Open Recent goes through here too).
    public func open(_ url: URL, confirmed: Bool = false) {
        guard confirmed || confirmDiscardingChanges() else { return }
        do {
            let result = try Self.read(url)
            var next = result.settings
            next.isBypassed = settings.isBypassed
            setSettings(next)
            markSaved(at: url)
            resetHistory()
            showWarnings(result.warnings, title: "Some lines of “\(url.lastPathComponent)” were skipped")
        } catch {
            recentURLs.removeAll { $0 == url }
            NSAlert(error: error).runModal()
        }
    }

    /// Saves to the current file, or asks where when the EQ is untitled. `true` when it saved.
    @discardableResult
    public func save() -> Bool {
        guard let url = documentURL else { return saveAs() }
        return write(to: url, makingCurrent: true)
    }

    @discardableResult
    public func saveAs() -> Bool {
        guard let url = askForDestination(title: "Save As", name: displayName) else { return false }
        return write(to: url, makingCurrent: true)
    }

    /// Loads another file's EQ as one undo step; the current file stays the same.
    public func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.message = "Import an Equalizer APO file into the current EQ"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try Self.read(url)
            replace(with: result.settings, actionName: "Import")
            showWarnings(result.warnings, title: "Some lines of “\(url.lastPathComponent)” were skipped")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Writes the current EQ to another file without changing which file is current.
    public func exportFile() {
        guard let url = askForDestination(title: "Export", name: displayName) else { return }
        write(to: url, makingCurrent: false)
    }

    // MARK: Presets

    public func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "A preset with the same name is replaced."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        field.stringValue = documentURL == nil ? "" : displayName
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        presets.save(name: field.stringValue, settings: settings)
    }

    public func loadPreset(_ preset: EQPreset) {
        replace(with: preset.settings, actionName: "Load Preset")
    }

    public func deletePreset(_ preset: EQPreset) {
        let alert = NSAlert()
        alert.messageText = "Delete the preset “\(preset.name)”?"
        alert.informativeText = "This can’t be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        presets.delete(preset.id)
    }

    // MARK: Helpers

    /// Reads a file as UTF-8, falling back to Latin-1 for older Windows files.
    private static func read(_ url: URL) throws -> EqualizerAPOImporter.Result {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return try EqualizerAPOImporter.parse(text)
    }

    @discardableResult
    private func write(to url: URL, makingCurrent: Bool) -> Bool {
        do {
            try EqualizerAPOExporter.export(settings).write(to: url, atomically: true, encoding: .utf8)
            if makingCurrent { markSaved(at: url) }
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    private func askForDestination(title: String, name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(name).\(EqualizerAPOExporter.fileExtension)"
        panel.message = "Equalizer APO text, readable by other equalizer apps"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func showWarnings(_ warnings: [String], title: String) {
        guard !warnings.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = warnings.joined(separator: "\n")
        alert.runModal()
    }
}
