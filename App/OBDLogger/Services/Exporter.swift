import Foundation
import OBDKit

/// Writes finished trips as CSV into a folder the user picked in the Files app (iCloud
/// Drive, Google Drive, OneDrive, ...; the provider syncs it), and optionally uploads
/// them to an InfluxDB 2.x server.
enum Exporter {
    enum ExportError: LocalizedError {
        case noFolder
        case folderUnavailable
        case upload(String)

        var errorDescription: String? {
            switch self {
            case .noFolder: return "No export folder chosen."
            case .folderUnavailable: return "The export folder can't be opened. Choose it again in Settings."
            case .upload(let m): return m
            }
        }
    }

    static func bookmark(for url: URL) throws -> Data {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func infos(for trip: TripData) -> [SignalID: SignalInfo] {
        var infos: [SignalID: SignalInfo] = [:]
        for i in StandardPIDs.signalInfos + DerivedSignals.infos + GPSSignals.infos + AdapterSignals.infos { infos[i.id] = i }
        for p in BuiltInProfiles.all { for s in p.sensors { infos[s.signalID] = s.info } }
        for i in trip.meta.signals { infos[i.id] = i }
        return infos
    }

    struct Files: Sendable {
        var wide: URL?
        var raw: URL?
    }

    /// Writes the requested CSVs into `directory` (temporary or the picked folder).
    static func writeCSV(_ trip: TripData, settings: SettingsData, to directory: URL) throws -> Files {
        let infos = infos(for: trip)
        var files = Files()
        let base = trip.meta.id
        if settings.exportWide {
            let url = directory.appendingPathComponent("\(base).csv")
            let text = CSVExport.wide(trip, infos: infos, prefs: settings.prefs, step: settings.exportStep,
                                      includeAge: settings.exportAgeColumns)
            try coordinatedWrite(Data(text.utf8), to: url)
            files.wide = url
        }
        if settings.exportRaw {
            let url = directory.appendingPathComponent("\(base)-raw.csv")
            try coordinatedWrite(Data(CSVExport.raw(trip, infos: infos).utf8), to: url)
            files.raw = url
        }
        return files
    }

    /// Exports into the user's chosen folder.
    static func exportToFolder(_ trip: TripData, settings: SettingsData) throws {
        guard let bookmark = settings.exportFolderBookmark else { throw ExportError.noFolder }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw ExportError.folderUnavailable
        }
        let ok = folder.startAccessingSecurityScopedResource()
        defer { if ok { folder.stopAccessingSecurityScopedResource() } }
        _ = try writeCSV(trip, settings: settings, to: folder)
    }

    /// Temporary copies for the share sheet.
    static func shareFiles(_ trip: TripData, settings: SettingsData) throws -> Files {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(trip.meta.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = settings
        s.exportWide = true
        s.exportRaw = true
        return try writeCSV(trip, settings: s, to: dir)
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let e = coordError ?? writeError { throw e }
    }

    // MARK: InfluxDB

    static let tokenAccount = "influx-token"

    /// Writes every reading as line protocol (`trip,vehicle=…,trip_id=…,source=obdlogger <signal>=<value> <ms>`).
    static func upload(_ trip: TripData, settings: SettingsData) async throws {
        guard let token = Keychain.get(tokenAccount), !token.isEmpty else { throw ExportError.upload("No InfluxDB token saved.") }
        let lines = InfluxLineProtocol.lines(trip, tags: ["vehicle": settings.influxVehicle, "trip_id": trip.meta.id, "source": "obdlogger"])
        var start = 0
        while start < lines.count {
            let batch = lines[start..<min(lines.count, start + 5000)].joined(separator: "\n")
            try await post(batch, settings: settings, token: token)
            start += 5000
        }
    }

    static func testConnection(settings: SettingsData) async throws {
        guard let token = Keychain.get(tokenAccount), !token.isEmpty else { throw ExportError.upload("No InfluxDB token saved.") }
        // An empty write checks the URL, organization, bucket and token without storing anything.
        try await post("", settings: settings, token: token)
    }

    private static func post(_ body: String, settings: SettingsData, token: String) async throws {
        var base = settings.influxURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard var comps = URLComponents(string: base + "/api/v2/write") else { throw ExportError.upload("Invalid InfluxDB URL.") }
        comps.queryItems = [URLQueryItem(name: "org", value: settings.influxOrg),
                            URLQueryItem(name: "bucket", value: settings.influxBucket),
                            URLQueryItem(name: "precision", value: "ms")]
        guard let url = comps.url else { throw ExportError.upload("Invalid InfluxDB URL.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ExportError.upload("No response from InfluxDB.") }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw ExportError.upload("InfluxDB said \(http.statusCode): \(message.prefix(200))")
        }
    }
}
