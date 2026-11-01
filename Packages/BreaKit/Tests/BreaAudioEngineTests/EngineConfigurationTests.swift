import BreaCore
import BreaDSP
import Foundation
import Testing
@testable import BreaAudioEngine

struct EngineConfigurationTests {
    @Test func roundTripsThroughJSON() throws {
        let configuration = EngineConfiguration(
            mode: .global,
            enabledApps: ["com.apple.Music", "com.spotify.client"],
            settings: [
                .global: ChainSettings(bands: [EQBand(type: .lowShelf, frequency: 90, gainDB: 4, q: 0.7)], pregainDB: -2),
                .app(bundleID: "com.apple.Music"): ChainSettings(headroom: .manual(dB: -6), isBypassed: true),
            ]
        )
        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(EngineConfiguration.self, from: data) == configuration)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(EngineConfiguration.self, from: Data(#"{"mode":"global"}"#.utf8))
        #expect(decoded.mode == .global)
        #expect(decoded.enabledApps.isEmpty && decoded.outputDeviceUID == nil)
    }
}
