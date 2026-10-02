import Foundation
import Observation
import OBDKit

/// Trips live in Documents/Trips (visible in the Files app under On My iPad), one folder
/// per trip. Capability maps live in Application Support.
@MainActor
@Observable
final class TripStore {
    struct Entry: Identifiable, Equatable {
        let directory: URL
        let meta: TripMeta
        var id: String { meta.id }
    }

    private(set) var trips: [Entry] = []

    let root: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Trips", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() { refresh() }

    func refresh() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        trips = dirs.compactMap { dir in
            (try? TripFiles.readMeta(dir)).map { Entry(directory: dir, meta: $0) }
        }.sorted { $0.meta.startedAt > $1.meta.startedAt }
    }

    func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.directory)
        refresh()
    }

    func entry(id: String) -> Entry? { trips.first { $0.id == id } }

    // MARK: capability maps

    private func capabilityURL(_ fingerprint: String) -> URL {
        // Stable short name from the fingerprint (FNV-1a).
        var hash: UInt64 = 0xcbf29ce484222325
        for b in fingerprint.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        return support.appendingPathComponent("capability-\(String(hash, radix: 16)).json")
    }

    func loadCapability(fingerprint: String) -> CapabilityMap {
        guard let data = try? Data(contentsOf: capabilityURL(fingerprint)),
              let map = try? JSONDecoder().decode(CapabilityMap.self, from: data),
              map.fingerprint == fingerprint else { return CapabilityMap(fingerprint: fingerprint) }
        return map
    }

    func saveCapability(_ map: CapabilityMap) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: capabilityURL(map.fingerprint), options: .atomic)
    }
}
