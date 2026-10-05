import Foundation

/// Every signal the app knows by ID: standard PIDs, derived values, GPS, the adapter's own
/// reading and the built-in vehicle profiles. A trip can carry more (an imported column with
/// no counterpart here); those are described in its own meta.json.
public enum SignalCatalog {
    public static let infos: [SignalID: SignalInfo] = {
        var out: [SignalID: SignalInfo] = [:]
        for i in StandardPIDs.signalInfos + DerivedSignals.infos + GPSSignals.infos + AdapterSignals.infos { out[i.id] = i }
        for p in BuiltInProfiles.all { for s in p.sensors { out[s.signalID] = s.info } }
        return out
    }()

    /// The catalog plus the trip's own signal descriptions (which win, so a profile change
    /// later doesn't rename what an older trip recorded).
    public static func infos(for trip: TripData) -> [SignalID: SignalInfo] {
        var out = infos
        for i in trip.meta.signals { out[i.id] = i }
        return out
    }

    /// Lowercased signal name -> ID, for reading files that name their columns.
    static let byName: [String: SignalID] = {
        var out: [String: SignalID] = [:]
        for (id, info) in infos.sorted(by: { $0.key < $1.key }) where out[info.name.lowercased()] == nil {
            out[info.name.lowercased()] = id
        }
        return out
    }()
}
