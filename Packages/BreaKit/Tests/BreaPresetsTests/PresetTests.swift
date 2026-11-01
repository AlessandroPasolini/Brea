import BreaDSP
import Foundation
import Testing
@testable import BreaPresets

func temporaryURL(_ name: String = "store.json") -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "BreaTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: name)
}

@MainActor
struct JSONFileStoreTests {
    @Test func roundTripsAfterFlush() {
        let url = temporaryURL()
        let store = JSONFileStore<[String: Int]>(url: url)
        #expect(store.load() == nil)
        store.save(["a": 1])
        store.save(["a": 2])   // coalesced
        store.flush()
        #expect(JSONFileStore<[String: Int]>(url: url).load() == ["a": 2])
    }

    @Test func debouncedSaveEventuallyWrites() async throws {
        let url = temporaryURL()
        let store = JSONFileStore<[Int]>(url: url, debounce: .milliseconds(20))
        store.save([1, 2, 3])
        try await Task.sleep(for: .milliseconds(200))
        #expect(JSONFileStore<[Int]>(url: url).load() == [1, 2, 3])
    }

    @Test func corruptFileIsMovedAside() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(JSONFileStore<[Int]>(url: url).load() == nil)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@MainActor
struct PresetLibraryTests {
    private func makeLibrary(url: URL = temporaryURL()) -> PresetLibrary {
        PresetLibrary(store: JSONFileStore(url: url, debounce: .milliseconds(1)))
    }

    @Test func saveOverwritesSameNameCaseInsensitively() {
        let library = makeLibrary()
        let first = library.save(name: "Night", settings: .standard)
        let second = library.save(name: "night", settings: ChainSettings(pregainDB: -3))
        #expect(first.id == second.id)
        #expect(library.userPresets.count == 1)
        #expect(library.userPresets[0].settings.pregainDB == -3)
    }

    @Test func factoryNamesAreNotShadowed() {
        let library = makeLibrary()
        let preset = library.save(name: "Flat", settings: .standard)
        #expect(preset.name == "Flat (Custom)")
        #expect(library.allPresets.filter { $0.name == "Flat" }.count == 1)
    }

    @Test func factoryPresetsCannotBeDeleted() {
        let library = makeLibrary()
        library.delete(FactoryPresets.flat.id)
        #expect(library.preset(id: FactoryPresets.flat.id) != nil)
    }

    @Test func persistsAcrossInstances() {
        let url = temporaryURL()
        let library = makeLibrary(url: url)
        let preset = library.save(name: "Desk", settings: ChainSettings(bands: [EQBand(gainDB: 2)], headroom: .manual(dB: -3)))
        library.rename(preset.id, to: "Desk Speakers")
        library.flush()
        let reloaded = makeLibrary(url: url)
        #expect(reloaded.userPresets == [EQPreset(id: preset.id, name: "Desk Speakers", settings: preset.settings)])
    }

    @Test func factoryPresetsAreStableAndSafe() {
        #expect(Set(FactoryPresets.all.map(\.id)).count == FactoryPresets.all.count)
        for preset in FactoryPresets.all {
            #expect(preset.settings.bands.count <= ProcessingChain.maxBands)
            #expect(preset.settings.headroom == .manual(dB: 0))   // no automatic level changes
        }
    }
}
