import BreaDSP
import Foundation

/// A named, reusable chain configuration, stored locally by ``PresetLibrary``.
public struct EQPreset: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var settings: ChainSettings

    public init(id: UUID = UUID(), name: String, settings: ChainSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }
}

/// The built-in presets. Their identifiers are fixed, so references to them survive relaunches,
/// and their names are reserved: user presets never shadow them.
public enum FactoryPresets {
    public static let flat = EQPreset(id: uuid("00000000-0000-0000-0000-000000000001"), name: "Flat", settings: .standard)

    public static let all: [EQPreset] = [
        flat,
        EQPreset(id: uuid("00000000-0000-0000-0000-000000000002"), name: "Bass Boost", settings: ChainSettings(bands: [
            EQBand(type: .lowShelf, frequency: 100, gainDB: 6, q: 0.7071),
            EQBand(type: .peak, frequency: 250, gainDB: -1.5, q: 1.2),
        ])),
        EQPreset(id: uuid("00000000-0000-0000-0000-000000000003"), name: "Treble Boost", settings: ChainSettings(bands: [
            EQBand(type: .highShelf, frequency: 8_000, gainDB: 4, q: 0.7071),
        ])),
        EQPreset(id: uuid("00000000-0000-0000-0000-000000000004"), name: "Vocal Presence", settings: ChainSettings(bands: [
            EQBand(type: .highPass, frequency: 80, q: 0.7071),
            EQBand(type: .peak, frequency: 300, gainDB: -2, q: 1),
            EQBand(type: .peak, frequency: 3_000, gainDB: 3, q: 1),
        ])),
        EQPreset(id: uuid("00000000-0000-0000-0000-000000000005"), name: "Loudness", settings: ChainSettings(bands: [
            EQBand(type: .lowShelf, frequency: 80, gainDB: 5, q: 0.7071),
            EQBand(type: .peak, frequency: 1_000, gainDB: -1, q: 0.8),
            EQBand(type: .highShelf, frequency: 10_000, gainDB: 4, q: 0.7071),
        ])),
    ]

    private static func uuid(_ string: String) -> UUID {
        guard let id = UUID(uuidString: string) else { preconditionFailure("Invalid factory preset UUID") }
        return id
    }
}
