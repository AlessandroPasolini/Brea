import BreaPresets
import SwiftUI

/// The menu bar.
///
/// | Menu | Contents |
/// |---|---|
/// | Brea | About (with the full version, see ``BreaVersion``), then the system's: Settings…, Services, Hide, Show All, Quit. |
/// | File | New · Import…, Export… · Save · Open…, Open Recent · Save As… · Save Preset…, Load Preset, Delete Preset. |
/// | Edit | Undo, Redo, Cut, Copy, Paste, Select All (the clipboard commands act on value fields). |
/// | Window | The system's. |
///
/// File commands treat the EQ as an Equalizer APO document (see ``EditorModel``); presets are
/// local to this Mac. SwiftUI's default Save, Import/Export, Print, text editing and text
/// formatting groups are removed; the File items above replace them.
public struct BreaCommands: Commands {
    private let model: EditorModel

    public init(model: EditorModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Brea") { BreaVersion.showAboutPanel() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New") { model.newDocument() }
                .keyboardShortcut("n")
            Divider()
            Button("Import…") { model.importFile() }
                .keyboardShortcut("i")
            Button("Export…") { model.exportFile() }
                .keyboardShortcut("e")
            Divider()
            Button("Save") { model.save() }
                .keyboardShortcut("s")
            Divider()
            Button("Open…") { model.openDocument() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(model.recentURLs, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { model.open(url) }
                }
                if !model.recentURLs.isEmpty { Divider() }
                Button("Clear Menu") { model.clearRecents() }
                    .disabled(model.recentURLs.isEmpty)
            }
            Divider()
            Button("Save As…") { model.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Save Preset…") { model.savePreset() }
            Menu("Load Preset") {
                Section("Factory") {
                    ForEach(FactoryPresets.all) { preset in
                        Button(preset.name) { model.loadPreset(preset) }
                    }
                }
                if !model.presets.userPresets.isEmpty {
                    Section("My Presets") {
                        ForEach(model.presets.userPresets) { preset in
                            Button(preset.name) { model.loadPreset(preset) }
                        }
                    }
                }
            }
            Menu("Delete Preset") {
                ForEach(model.presets.userPresets) { preset in
                    Button(preset.name) { model.deletePreset(preset) }
                }
            }
            .disabled(model.presets.userPresets.isEmpty)
        }
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .importExport) {}
        CommandGroup(replacing: .printItem) {}
        CommandGroup(replacing: .textEditing) {}
        CommandGroup(replacing: .textFormatting) {}
    }
}
