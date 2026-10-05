import Foundation
import Observation
import OBDKit

/// Brings trips recorded elsewhere onto this device, so the iPhone can show what the iPad
/// recorded: CSV files picked in the Files app or sent here from another app (Car Scanner's
/// Share › CSV), and a linked folder that is checked for new exports. Linking the folder the
/// iPad exports into picks up its trips, and any Car Scanner CSVs kept there, on their own.
///
/// A trip already on this device (same trip ID) is never read again, and an imported trip is
/// never exported or uploaded from here: its source already has it.
@MainActor
@Observable
final class TripImporter {
    private(set) var isRunning = false
    private(set) var progress: (done: Int, total: Int)?
    /// Outcome of the last import, shown on the Trips list.
    private(set) var status: String?
    private(set) var lastCheck: Date?

    private let store: TripStore
    private let settings: AppSettings
    private static let ignoredKey = "import.notTrips"

    init(store: TripStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    // MARK: linked folder

    func linkFolder(_ url: URL) {
        guard let bookmark = try? Exporter.bookmark(for: url) else {
            status = "That folder can't be linked."
            return
        }
        settings.update {
            $0.importFolderBookmark = bookmark
            $0.importFolderName = url.lastPathComponent
        }
        UserDefaults.standard.removeObject(forKey: Self.ignoredKey)
        Task { await checkLinkedFolder() }
    }

    func unlinkFolder() {
        settings.update {
            $0.importFolderBookmark = nil
            $0.importFolderName = nil
        }
        UserDefaults.standard.removeObject(forKey: Self.ignoredKey)
        status = nil
    }

    /// Checks the linked folder when the app comes to the front (at most every few minutes).
    func appBecameActive() {
        guard settings.data.importOnOpen, settings.data.importFolderBookmark != nil, !isRunning else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 180 { return }
        Task { await checkLinkedFolder() }
    }

    /// Imports every trip in the linked folder (and its subfolders) that isn't here yet.
    func checkLinkedFolder() async {
        guard !isRunning, let bookmark = settings.data.importFolderBookmark else { return }
        let name = settings.data.importFolderName ?? "the folder"
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            status = "\(name) can't be opened any more. Link it again in Settings."
            return
        }
        if stale, let fresh = try? Exporter.bookmark(for: folder) { settings.update { $0.importFolderBookmark = fresh } }
        lastCheck = Date()
        let ignored = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredKey) ?? [])
        await run(source: name) { existing in
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            Self.refreshListing(folder)
            let files = Self.pickPerTrip(Self.scan(folder)).filter { url in
                guard let id = TripImport.tripID(fromFileName: url.lastPathComponent) else { return false }
                return !existing.contains(id) && !ignored.contains(url.path)
            }
            return (files, { body in
                let a = folder.startAccessingSecurityScopedResource()
                defer { if a { folder.stopAccessingSecurityScopedResource() } }
                return body()
            })
        }
    }

    // MARK: files

    /// Files picked in the Files app or opened from another app.
    func importFiles(_ urls: [URL]) async {
        guard !isRunning, !urls.isEmpty else { return }
        await run(source: nil) { existing in
            let files = Self.pickPerTrip(urls).filter { url in
                TripImport.tripID(fromFileName: url.lastPathComponent).map { !existing.contains($0) } ?? true
            }
            return (files, { body in body() })
        }
        // Copies iOS made in Documents/Inbox for "Open in" are ours to remove.
        for url in urls where url.path.contains("/Documents/Inbox/") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: running

    private enum FileResult: Sendable {
        case imported(String)
        case alreadyHere
        case notATrip
        case failed(String)
    }

    /// `prepare` runs off the main thread: it lists the files to read (given the trip IDs
    /// already here) and wraps the reading in whatever folder access it needs.
    private func run(source: String?,
                     prepare: @escaping @Sendable (Set<String>) -> ([URL], (() -> [(URL, FileResult)]) -> [(URL, FileResult)])) async {
        isRunning = true
        progress = nil
        status = source.map { "Checking \($0)…" } ?? "Importing…"
        let existing = Set(store.trips.map(\.id))
        let root = store.root
        let version = LoggerEngine.appVersion
        // The importer lives as long as the app, so the work can hold on to it.
        let results: [(URL, FileResult)] = await Task.detached(priority: .userInitiated) { [self] in
            let (files, withAccess) = prepare(existing)
            await MainActor.run { self.progress = files.isEmpty ? nil : (0, files.count) }
            return withAccess {
                var out: [(URL, FileResult)] = []
                for (i, url) in files.enumerated() {
                    out.append((url, Self.importOne(url, root: root, appVersion: version)))
                    let done = i + 1
                    Task { @MainActor in self.progress = (done, files.count) }
                }
                return out
            }
        }.value
        store.refresh()
        remember(results)
        status = Self.summary(results, source: source)
        progress = nil
        isRunning = false
    }

    private func remember(_ results: [(URL, FileResult)]) {
        let notTrips = results.compactMap { url, r -> String? in if case .notATrip = r { return url.path } else { return nil } }
        guard !notTrips.isEmpty else { return }
        let old = UserDefaults.standard.stringArray(forKey: Self.ignoredKey) ?? []
        UserDefaults.standard.set(Array(Set(old + notTrips)), forKey: Self.ignoredKey)
    }

    private static func summary(_ results: [(URL, FileResult)], source: String?) -> String {
        var imported = 0, here = 0, notTrips = 0
        var failures: [String] = []
        for (url, r) in results {
            switch r {
            case .imported: imported += 1
            case .alreadyHere: here += 1
            case .notATrip: notTrips += 1
            case .failed(let why): failures.append("\(url.lastPathComponent): \(why)")
            }
        }
        var parts: [String] = []
        let from = source.map { " from \($0)" } ?? ""
        if imported > 0 {
            parts.append("Imported \(imported) trip\(imported == 1 ? "" : "s")\(from).")
        } else if failures.isEmpty {
            parts.append(source.map { "Nothing new in \($0)." } ?? "Nothing new to import.")
        }
        if here > 0 { parts.append("\(here) already here.") }
        if notTrips > 0 { parts.append("\(notTrips) file\(notTrips == 1 ? " isn't a trip export" : "s aren't trip exports").") }
        if !failures.isEmpty {
            parts.append("Couldn't import \(failures.count): " + failures.prefix(3).joined(separator: "; ")
                         + (failures.count > 3 ? "; …" : ""))
        }
        return parts.joined(separator: " ")
    }

    // MARK: file work (off the main thread)

    private nonisolated static func importOne(_ url: URL, root: URL, appVersion: String) -> FileResult {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try read(url)
            let imported = try TripImport.parse(data, fileName: url.lastPathComponent, appVersion: appVersion)
            try TripImport.write(imported.trip, to: root)
            return .imported(imported.trip.meta.id)
        } catch TripImport.ImportError.exists(_) {
            return .alreadyHere
        } catch TripImport.ImportError.unrecognized {
            return .notATrip
        } catch let error as TripImport.ImportError {
            return .failed(error.description)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Reads through a file coordinator, which makes iCloud Drive (or another provider)
    /// download a file that is only a placeholder on this device.
    private nonisolated static func read(_ url: URL) throws -> Data {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { target in
            result = Result { try Data(contentsOf: target) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Asks the folder's provider for a current listing before it is read.
    private nonisolated static func refreshListing(_ folder: URL) {
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: folder, options: [.withoutChanges], error: &error) { _ in }
    }

    /// CSV files in `folder` and its subfolders (another tool may have filed exports away
    /// there). iCloud lists files not yet on this device as ".<name>.icloud".
    private nonisolated static func scan(_ folder: URL, depth: Int = 3) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return []
        }
        var out: [URL] = []
        for item in items {
            let name = item.lastPathComponent
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if depth > 0, !name.hasPrefix(".") { out += scan(item, depth: depth - 1) }
                continue
            }
            var real = name
            if name.hasPrefix("."), name.hasSuffix(".icloud") { real = String(name.dropFirst().dropLast(".icloud".count)) }
            guard real.lowercased().hasSuffix(".csv") else { continue }
            out.append(item.deletingLastPathComponent().appendingPathComponent(real))
        }
        return out
    }

    /// One file per trip: the raw export when there is one (exact readings), otherwise the
    /// shortest name ("2026-09-03 14-46-15.csv" over its sync duplicate "… 2.csv").
    /// Files whose names carry no trip ID are passed through.
    private nonisolated static func pickPerTrip(_ urls: [URL]) -> [URL] {
        func rank(_ url: URL) -> (Int, Int) {
            (TripImport.isRawExport(fileName: url.lastPathComponent) ? 0 : 1, url.lastPathComponent.count)
        }
        var best: [String: URL] = [:]
        var loose: [URL] = []
        for url in urls {
            guard let id = TripImport.tripID(fromFileName: url.lastPathComponent) else {
                loose.append(url)
                continue
            }
            if let current = best[id], rank(current) <= rank(url) { continue }
            best[id] = url
        }
        return best.keys.sorted().map { best[$0]! } + loose
    }
}
