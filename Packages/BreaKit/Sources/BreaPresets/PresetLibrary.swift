import BreaDSP
import Foundation
import Observation

/// The factory presets plus the user's own, which are persisted through a ``JSONFileStore``.
///
/// Presets are local to this Mac; Equalizer APO documents are the format for sharing.
///
/// ## Naming rules
/// - Names are trimmed; an empty name becomes "Untitled".
/// - Names compare case- and diacritic-insensitively.
/// - Saving under an existing user preset's name overwrites it.
/// - A factory name gets a " (Custom)" suffix, so built-ins are never shadowed.
@MainActor
@Observable
public final class PresetLibrary {
    public private(set) var userPresets: [EQPreset]

    @ObservationIgnored private let store: JSONFileStore<[EQPreset]>

    public init(store: JSONFileStore<[EQPreset]>) {
        self.store = store
        userPresets = store.load() ?? []
    }

    public var allPresets: [EQPreset] { FactoryPresets.all + userPresets }

    public func preset(id: UUID) -> EQPreset? {
        allPresets.first { $0.id == id }
    }

    /// Saves `settings` under `name`, following the naming rules above.
    @discardableResult
    public func save(name: String, settings: ChainSettings) -> EQPreset {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Untitled" }
        if FactoryPresets.all.contains(where: { Self.sameName($0.name, name) }) { name += " (Custom)" }

        if let index = userPresets.firstIndex(where: { Self.sameName($0.name, name) }) {
            userPresets[index].settings = settings
            persist()
            return userPresets[index]
        }
        let preset = EQPreset(name: name, settings: settings)
        userPresets.append(preset)
        persist()
        return preset
    }

    public func rename(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = userPresets.firstIndex(where: { $0.id == id }) else { return }
        userPresets[index].name = trimmed
        persist()
    }

    /// Deletes a user preset. Factory presets cannot be deleted.
    public func delete(_ id: UUID) {
        userPresets.removeAll { $0.id == id }
        persist()
    }

    public func flush() { store.flush() }

    private func persist() { store.save(userPresets) }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
