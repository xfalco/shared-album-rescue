import Foundation

/// Everything known about one shared-album asset, across every place a copy could live.
struct AssetFacts {
    let asset: SharedAsset
    let album: SharedAlbum?
    let localFile: URL?
    let backupFile: URL?
    let staged: Bool
    let imported: Bool

    /// A copy of this asset exists somewhere under our control.
    var covered: Bool { localFile != nil || backupFile != nil || staged || imported }
    var albumTitle: String { album?.title ?? "(unknown album)" }
}

struct AlbumReport: Codable {
    let title: String
    let scopeID: String
    let ownedByMe: Bool
    var total = 0
    var photos = 0
    var videos = 0
    var mine = 0
    var others = 0
    var localPresent = 0
    var backupOnly = 0
    var stagedOrImported = 0
    var othersCloudOnly = 0
}

struct ScanTotals: Codable {
    var total = 0
    var mine = 0
    var others = 0
    var localPresent = 0
    var backupOnly = 0
    var staged = 0
    var imported = 0
    var othersCovered = 0
    var othersCloudOnly = 0
    var othersWithLocation = 0
}

struct ScanReport: Codable {
    let generatedAt: Date
    let libraryPath: String
    let backupLibraryPath: String?
    let albums: [AlbumReport]
    let totals: ScanTotals
}

struct ScanCore {
    let library: URL
    let backupLibrary: URL?
    let state: StateStore

    func gather() throws -> (albums: [SharedAlbum], facts: [AssetFacts]) {
        let db = try PhotosDB.openCopy(of: library, scratchIn: state.tmpDir)
        let albums = try db.sharedAlbums()
        let assets = try db.sharedAssets()
        let albumsByScope = Dictionary(albums.map { ($0.scopeID, $0) }, uniquingKeysWith: { first, _ in first })

        // The backup's local filenames differ from the live library's (Photos migrations
        // re-key them), so backup files are located through its own database, joined by
        // cloud GUID.
        var backupFiles: [String: URL] = [:]
        if let backupLibrary {
            let backupDB = try PhotosDB.openCopy(of: backupLibrary, scratchIn: state.tmpDir)
            for backupAsset in try backupDB.sharedAssets() where !backupAsset.cloudGUID.isEmpty {
                let url = backupAsset.fileURL(inLibrary: backupLibrary)
                if FileManager.default.fileExists(atPath: url.path) {
                    backupFiles[backupAsset.cloudGUID] = url
                }
            }
        }

        let ledger = state.loadLedger()
        let manifest = state.loadManifest()
        let fm = FileManager.default

        let facts = assets.map { asset -> AssetFacts in
            let local = asset.fileURL(inLibrary: library)
            let stagedItem = manifest[asset.cloudGUID]
            return AssetFacts(
                asset: asset,
                album: albumsByScope[asset.scopeID],
                localFile: fm.fileExists(atPath: local.path) ? local : nil,
                backupFile: backupFiles[asset.cloudGUID],
                staged: stagedItem.map { state.stagedFileExists($0) } ?? false,
                imported: ledger[asset.cloudGUID] != nil
            )
        }
        return (albums, facts)
    }

    func report(albums: [SharedAlbum], facts: [AssetFacts]) -> ScanReport {
        var perAlbum: [String: AlbumReport] = [:]
        var totals = ScanTotals()

        for fact in facts {
            let key = fact.album?.scopeID ?? "?"
            var entry = perAlbum[key] ?? AlbumReport(
                title: fact.albumTitle,
                scopeID: fact.album?.scopeID ?? "",
                ownedByMe: fact.album?.ownedByMe ?? false
            )
            entry.total += 1
            if fact.asset.isVideo { entry.videos += 1 } else { entry.photos += 1 }
            if fact.asset.isMine { entry.mine += 1 } else { entry.others += 1 }
            if fact.localFile != nil { entry.localPresent += 1 }
            if fact.localFile == nil && fact.backupFile != nil { entry.backupOnly += 1 }
            if fact.staged || fact.imported { entry.stagedOrImported += 1 }
            if !fact.asset.isMine && !fact.covered { entry.othersCloudOnly += 1 }
            perAlbum[key] = entry

            totals.total += 1
            if fact.asset.isMine { totals.mine += 1 } else { totals.others += 1 }
            if fact.localFile != nil { totals.localPresent += 1 }
            if fact.localFile == nil && fact.backupFile != nil { totals.backupOnly += 1 }
            if fact.staged { totals.staged += 1 }
            if fact.imported { totals.imported += 1 }
            if !fact.asset.isMine {
                if fact.covered { totals.othersCovered += 1 } else { totals.othersCloudOnly += 1 }
                if fact.asset.hasLocation { totals.othersWithLocation += 1 }
            }
        }

        let sorted = perAlbum.values.sorted { $0.total > $1.total }
        return ScanReport(
            generatedAt: Date(),
            libraryPath: library.path,
            backupLibraryPath: backupLibrary?.path,
            albums: sorted,
            totals: totals
        )
    }

    static func printTable(_ report: ScanReport) {
        let header = Format.pad("ALBUM", 36) + Format.pad("own", 5)
            + Format.pad("items", 7, alignRight: true) + Format.pad("mine", 6, alignRight: true)
            + Format.pad("others", 8, alignRight: true) + Format.pad("local", 7, alignRight: true)
            + Format.pad("bakOnly", 9, alignRight: true) + Format.pad("secured", 9, alignRight: true)
            + Format.pad("cloudOnly", 11, alignRight: true)
        print(header)
        print(String(repeating: "-", count: header.count))
        for album in report.albums {
            print(
                Format.pad(album.title, 36)
                + Format.pad(album.ownedByMe ? "me" : "sub", 5)
                + Format.pad(String(album.total), 7, alignRight: true)
                + Format.pad(String(album.mine), 6, alignRight: true)
                + Format.pad(String(album.others), 8, alignRight: true)
                + Format.pad(String(album.localPresent), 7, alignRight: true)
                + Format.pad(String(album.backupOnly), 9, alignRight: true)
                + Format.pad(String(album.stagedOrImported), 9, alignRight: true)
                + Format.pad(String(album.othersCloudOnly), 11, alignRight: true)
            )
        }
        let t = report.totals
        print("""

        Totals: \(t.total) shared assets — \(t.mine) mine, \(t.others) from others.
          Local in live library : \(t.localPresent)
          Only in backup library: \(t.backupOnly)
          Staged                : \(t.staged)
          Imported              : \(t.imported)
          Others' assets covered somewhere: \(t.othersCovered) of \(t.others)
          Others' assets CLOUD-ONLY       : \(t.othersCloudOnly)  ← at risk
          Others' assets with GPS         : \(t.othersWithLocation)
        """)
    }
}
