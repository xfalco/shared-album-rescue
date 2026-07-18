import ArgumentParser
import Foundation

struct SyncStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-status",
        abstract: "Report iCloud sync health: overall library upload/download by default, shared-album cache and rescue coverage with --shared-albums."
    )

    @OptionGroup var options: LibraryOptions

    @Flag(help: "Report shared-album sync and rescue coverage instead of the overall library.")
    var sharedAlbums = false

    func run() throws {
        let state = try options.makeStateStore()
        if sharedAlbums {
            try reportSharedAlbums(state: state)
        } else {
            try reportLibrary(state: state)
        }
    }

    private func reportLibrary(state: StateStore) throws {
        let db = try PhotosDB.openCopy(of: options.libraryURL, scratchIn: state.tmpDir)
        let counts = try db.librarySyncCounts()
        let engine = engineDates()

        print("iCloud Photos library sync — \(options.libraryURL.lastPathComponent)")
        print(String(repeating: "-", count: 64))
        print("  Library assets        : \(counts.total)")
        print("  Synced with iCloud    : \(counts.synced)")
        if counts.awaitingUpload > 0 {
            print("  ⬆️ Awaiting upload     : \(counts.awaitingUpload) — keep Photos open on AC power; watch for an iCloud-storage banner")
        } else {
            print("  ⬆️ Awaiting upload     : 0 ✅")
        }
        for entry in counts.otherStates {
            print("  Cloud state \(entry.state)         : \(entry.count)")
        }
        print("  ⬇️ Added last 24h / 7d : \(counts.addedLastDay) / \(counts.addedLastWeek)")
        if let newest = counts.newestAdded {
            print("  Newest asset added    : \(Self.format(newest))")
        }
        if let initial = engine.initialSync {
            print("  Engine initial sync   : \(Self.format(initial)) — what the UI's stale “Last Synced” label tends to show")
        }
        if let last = engine.lastSyncAfterLaunch {
            print("  Engine last active    : \(Self.format(last))")
        }
    }

    private func reportSharedAlbums(state: StateStore) throws {
        let core = ScanCore(library: options.libraryURL, backupLibrary: nil, state: state)
        let (albums, facts) = try core.gather()
        let owned = albums.filter(\.ownedByMe).count
        let others = facts.filter { !$0.asset.isMine }
        let cached = facts.filter { $0.localFile != nil }.count
        let imported = facts.filter(\.imported).count
        let staged = facts.filter(\.staged).count
        let uncovered = others.filter { !$0.covered }

        print("Shared-album sync — \(albums.count) albums (\(owned) owned, \(albums.count - owned) subscribed)")
        print(String(repeating: "-", count: 64))
        print("  Shared assets         : \(facts.count) (\(facts.count - others.count) mine, \(others.count) from others)")
        print("  Locally cached files  : \(cached) — macOS evicts these; the cache is not a backup")
        print("  Imported / staged     : \(imported) / \(staged)")
        if let newest = facts.compactMap(\.asset.addedDate).max() {
            print("  Latest shared activity: \(Self.format(newest))")
        }
        if uncovered.isEmpty {
            print("  ✅ Every item from others is secured (in library, staged, or imported)")
        } else {
            print("  ☁️ NOT yet secured     : \(uncovered.count) — run `rescue`, then `download` and `import`:")
            let byAlbum = Dictionary(grouping: uncovered, by: \.albumTitle)
            for (album, items) in byAlbum.sorted(by: { $0.value.count > $1.value.count }).prefix(6) {
                print("      \(Format.pad(album, 38)) \(items.count)")
            }
        }
    }

    private func engineDates() -> (initialSync: Date?, lastSyncAfterLaunch: Date?) {
        let root = options.libraryURL.appendingPathComponent("resources/cpl/cloudsync.noindex")
        func plistDate(file: String, key: String) -> Date? {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(file)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return plist[key] as? Date
        }
        return (
            plistDate(file: "syncstatus.plist", key: "initialSyncDate"),
            plistDate(file: "lastsyncafterlaunch.plist", key: "date")
        )
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
