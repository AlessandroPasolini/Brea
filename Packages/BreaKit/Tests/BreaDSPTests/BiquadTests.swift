import Testing
@testable import BreaDSP

struct BiquadTests {
    @Test(arguments: [44_100.0, 48_000, 96_000])
    func peakHitsGainAtCenter(fs: Double) {
        let band = EQBand(type: .peak, frequency: 1_000, gainDB: 12, q: 1)
        let c = BiquadCoefficients(band, sampleRate: fs)
        #expect(abs(c.magnitudeDB(at: 1_000, sampleRate: fs) - 12) < 0.01)
    }

    @Test func zeroGainPeakIsFlat() {
        let c = BiquadCoefficients(EQBand(gainDB: 0), sampleRate: 48_000)
        for f in [30.0, 500, 5_000, 15_000] {
            #expect(abs(c.magnitudeDB(at: f, sampleRate: 48_000)) < 1e-6)
        }
    }

    @Test func lowPassIsMinus3dBAtCutoff() {
        let band = EQBand(type: .lowPass, frequency: 2_000, q: 0.7071)
        let c = BiquadCoefficients(band, sampleRate: 48_000)
        #expect(abs(c.magnitudeDB(at: 2_000, sampleRate: 48_000) + 3.01) < 0.05)
    }

    @Test func shelvesReachFullGainAwayFromCorner() {
        let low = BiquadCoefficients(EQBand(type: .lowShelf, frequency: 200, gainDB: 6, q: 0.7071), sampleRate: 48_000)
        let high = BiquadCoefficients(EQBand(type: .highShelf, frequency: 8_000, gainDB: -6, q: 0.7071), sampleRate: 48_000)
        #expect(abs(low.magnitudeDB(at: 20, sampleRate: 48_000) - 6) < 0.2)
        #expect(abs(high.magnitudeDB(at: 20_000, sampleRate: 48_000) + 6) < 0.3)
    }

    @Test func disabledBandIsIdentity() {
        let c = BiquadCoefficients(EQBand(gainDB: 12, isEnabled: false), sampleRate: 48_000)
        #expect(c == BiquadCoefficients())
    }

    @Test func stableAcrossParameterRange() {
        for fs in [44_100.0, 48_000, 96_000] {
            for type in FilterType.allCases {
                for f in [20.0, 100, 1_000, 10_000, 20_000] {
                    for q in [0.1, 0.7, 5, 18] {
                        for g in [-24.0, 0, 24] {
                            let c = BiquadCoefficients(EQBand(type: type, frequency: f, gainDB: g, q: q), sampleRate: fs)
                            #expect(c.isStable)
                        }
                    }
                }
            }
        }
    }
}
