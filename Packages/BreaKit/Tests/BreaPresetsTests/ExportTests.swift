import BreaDSP
import Foundation
import Testing
@testable import BreaPresets

struct EqualizerAPOExporterTests {
    @Test func roundTripsEverything() throws {
        let settings = ChainSettings(bands: [
            EQBand(type: .peak, frequency: 1_000, gainDB: -2.5, q: 1.4),
            EQBand(type: .lowShelf, frequency: 63, gainDB: 3, q: 0.7),
            EQBand(type: .highPass, frequency: 31.5, q: 0.707, isEnabled: false),
            EQBand(type: .notch, frequency: 4_000, q: 8),
        ], pregainDB: -3.5, headroom: .auto, isAutoPregain: true)

        let text = EqualizerAPOExporter.export(settings)
        let result = try EqualizerAPOImporter.parse(text)
        #expect(result.warnings.isEmpty)
        #expect(result.settings.hasSameSound(as: settings))
        #expect(result.settings.isAutoPregain && result.settings.headroom == .auto)
    }

    @Test func writesPlainAPOSyntax() {
        let text = EqualizerAPOExporter.export(ChainSettings(bands: [EQBand(frequency: 250, gainDB: 0, q: 1)]))
        #expect(text.contains("Preamp: 0 dB"))
        #expect(text.contains("Filter 1: ON PK Fc 250 Hz Gain 0 dB Q 1"))
        #expect(text.contains("# Brea: AutoGain Off"))
    }

    @Test func extensionsAreOptional() throws {
        let result = try EqualizerAPOImporter.parse("Preamp: -1 dB\nFilter 1: ON PK Fc 100 Hz Gain 2 dB Q 1")
        #expect(!result.settings.isAutoPregain && result.settings.headroom == .manual(dB: 0))
    }
}
