import Foundation
import SQLite3

// Schema notes (verified against Photos schema 5001, macOS 26):
// - Shared albums are rows in ZSHARE with ZSCOPETYPE = 0; ZSCOPEIDENTIFIER matches the
//   directory under scopes/cloudsharing/data/<personID>/.
// - Shared-album assets are ZASSET rows with ZBUNDLESCOPE = 2; ZDIRECTORY is
//   "<personID>/<scopeID>" and ZFILENAME the local cache file. Local filenames are
//   re-keyed by Photos migrations — ZCLOUDASSETGUID is the only durable identity.
// - ZCLOUDISMYASSET = 1 marks assets this account contributed.

struct SharedAlbum {
    let pk: Int64
    let title: String
    let scopeID: String
    let ownedByMe: Bool
    let status: Int64
}

struct SharedAsset {
    let pk: Int64
    let uuid: String
    let cloudGUID: String
    let directory: String
    let filename: String
    let isMine: Bool
    let isVideo: Bool
    let width: Int64
    let height: Int64
    let duration: Double
    let hasLocation: Bool
    let captureDate: Date?
    let originalFilename: String?
    let contributorID: String?
    let addedDate: Date?

    var scopeID: String {
        guard let slash = directory.firstIndex(of: "/") else { return directory }
        return String(directory[directory.index(after: slash)...])
    }

    func fileURL(inLibrary library: URL) -> URL {
        library
            .appendingPathComponent("scopes/cloudsharing/data")
            .appendingPathComponent(directory)
            .appendingPathComponent(filename)
    }
}

struct LibrarySyncCounts {
    let total: Int
    let synced: Int
    let awaitingUpload: Int
    let otherStates: [(state: Int64, count: Int)]
    let addedLastDay: Int
    let addedLastWeek: Int
    let newestAdded: Date?
}

struct SharedComment {
    let isLike: Bool
    let isCaption: Bool
    let isMine: Bool
    let date: Date?
    let text: String?
    let commenterID: String?
    let assetGUID: String?
    let assetDirectory: String?

    var assetScopeID: String? {
        guard let assetDirectory, let slash = assetDirectory.firstIndex(of: "/") else { return assetDirectory }
        return String(assetDirectory[assetDirectory.index(after: slash)...])
    }
}

final class PhotosDB {
    private var handle: OpaquePointer?
    private var tempDir: URL?

    /// Opens a read-only copy of the library's Photos.sqlite. The sqlite trio is copied
    /// into `scratchRoot` first so the live database (which photolibraryd keeps writing)
    /// is never opened directly. Callers pass the state volume's tmp dir so the
    /// multi-gigabyte copies stay off the internal disk; copies from crashed runs are
    /// swept once they're a day old (a running command never holds one that long).
    static func openCopy(of library: URL, scratchIn scratchRoot: URL) throws -> PhotosDB {
        let databaseDir = library.appendingPathComponent("database")
        let sqlite = databaseDir.appendingPathComponent("Photos.sqlite")
        guard FileManager.default.fileExists(atPath: sqlite.path) else {
            throw RescueError("No database/Photos.sqlite inside \(library.path) — is this a .photoslibrary?")
        }
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        if let stale = try? FileManager.default.contentsOfDirectory(
            at: scratchRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            for entry in stale {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, Date().timeIntervalSince(modified) > 86_400 {
                    try? FileManager.default.removeItem(at: entry)
                }
            }
        }
        let temp = scratchRoot.appendingPathComponent("db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let source = databaseDir.appendingPathComponent("Photos.sqlite\(suffix)")
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: temp.appendingPathComponent("Photos.sqlite\(suffix)"))
            }
        }
        let db = try PhotosDB(path: temp.appendingPathComponent("Photos.sqlite").path)
        db.tempDir = temp
        return db
    }

    init(path: String) throws {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(path, &opened, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle = opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(opened)
            throw RescueError("Cannot open \(path): \(message)")
        }
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    struct Row {
        let statement: OpaquePointer

        func string(_ index: Int32) -> String? {
            guard let text = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: text)
        }
        func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
        func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
    }

    func query<T>(_ sql: String, _ map: (Row) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw RescueError("SQL error: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(prepared) }
        var results: [T] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            results.append(try map(Row(statement: prepared)))
        }
        return results
    }
}

extension PhotosDB {
    func sharedAlbums() throws -> [SharedAlbum] {
        try query("""
            SELECT s.Z_PK, s.ZTITLE, s.ZSCOPEIDENTIFIER, s.ZSTATUS, MIN(p.ZROLE)
            FROM ZSHARE s
            LEFT JOIN ZSHAREPARTICIPANT p ON p.ZSHARE = s.Z_PK AND p.ZISCURRENTUSER = 1
            WHERE s.ZSCOPETYPE = 0
            GROUP BY s.Z_PK
            """) { row in
            SharedAlbum(
                pk: row.int(0),
                title: row.string(1) ?? "(untitled)",
                scopeID: row.string(2) ?? "",
                ownedByMe: row.int(4) == 1,
                status: row.int(3)
            )
        }
    }

    func sharedAssets() throws -> [SharedAsset] {
        try query("""
            SELECT a.Z_PK, a.ZUUID, a.ZCLOUDASSETGUID, a.ZDIRECTORY, a.ZFILENAME,
                   a.ZCLOUDISMYASSET, a.ZKIND, a.ZWIDTH, a.ZHEIGHT, a.ZDURATION,
                   a.ZLATITUDE, a.ZDATECREATED, aa.ZORIGINALFILENAME, a.ZCLOUDOWNERHASHEDPERSONID,
                   a.ZADDEDDATE
            FROM ZASSET a
            LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK
            WHERE a.ZBUNDLESCOPE = 2
            """) { row in
            SharedAsset(
                pk: row.int(0),
                uuid: row.string(1) ?? "",
                cloudGUID: row.string(2) ?? "",
                directory: row.string(3) ?? "",
                filename: row.string(4) ?? "",
                isMine: row.int(5) == 1,
                isVideo: row.int(6) == 1,
                width: row.int(7),
                height: row.int(8),
                duration: row.double(9),
                hasLocation: row.double(10) > -180,
                captureDate: row.isNull(11) ? nil : Format.appleDate(row.double(11)),
                originalFilename: row.string(12),
                contributorID: row.string(13),
                addedDate: row.isNull(14) ? nil : Format.appleDate(row.double(14))
            )
        }
    }

    /// Upload/download health of the main library: ZCLOUDLOCALSTATE 0 = awaiting
    /// upload, 1 = synced with iCloud; ZADDEDDATE tracks down-sync liveness.
    func librarySyncCounts(now: Date = Date()) throws -> LibrarySyncCounts {
        let states: [(Int64, Int)] = try query("""
            SELECT ZCLOUDLOCALSTATE, COUNT(*) FROM ZASSET
            WHERE ZBUNDLESCOPE = 0 AND ZTRASHEDSTATE = 0 GROUP BY 1
            """) { ($0.int(0), Int($0.int(1))) }
        let dayCut = now.timeIntervalSinceReferenceDate - 86_400
        let weekCut = now.timeIntervalSinceReferenceDate - 7 * 86_400
        let added = try query("""
            SELECT SUM(ZADDEDDATE > \(dayCut)), SUM(ZADDEDDATE > \(weekCut)), MAX(ZADDEDDATE)
            FROM ZASSET WHERE ZBUNDLESCOPE = 0 AND ZTRASHEDSTATE = 0
            """) { row -> (Int, Int, Double?) in
            (Int(row.int(0)), Int(row.int(1)), row.isNull(2) ? nil : row.double(2))
        }.first

        var total = 0
        var synced = 0
        var awaiting = 0
        var other: [(state: Int64, count: Int)] = []
        for (state, count) in states {
            total += count
            switch state {
            case 0: awaiting += count
            case 1: synced += count
            default: other.append((state, count))
            }
        }
        return LibrarySyncCounts(
            total: total, synced: synced, awaitingUpload: awaiting, otherStates: other,
            addedLastDay: added?.0 ?? 0, addedLastWeek: added?.1 ?? 0,
            newestAdded: (added?.2).flatMap { $0 }.map { Format.appleDate($0) }
        )
    }

    /// Keys of the form "lowercased-original-filename|capture-second" for every
    /// non-trashed library asset, with ±1s entries so clock jitter still matches.
    func libraryDedupIndex() throws -> Set<String> {
        var index = Set<String>()
        let rows: [(String, Int64)] = try query("""
            SELECT lower(aa.ZORIGINALFILENAME), CAST(a.ZDATECREATED AS INT)
            FROM ZASSET a
            JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK
            WHERE a.ZBUNDLESCOPE = 0 AND a.ZTRASHEDSTATE = 0
              AND aa.ZORIGINALFILENAME IS NOT NULL AND a.ZDATECREATED IS NOT NULL
            """) { ($0.string(0) ?? "", $0.int(1)) }
        for (filename, second) in rows where !filename.isEmpty {
            for delta in -1...1 {
                index.insert("\(filename)|\(second + Int64(delta))")
            }
        }
        return index
    }

    static func dedupKey(originalFilename: String, captureDate: Date) -> String {
        "\(originalFilename.lowercased())|\(Int64(captureDate.timeIntervalSinceReferenceDate))"
    }

    func sharedComments() throws -> [SharedComment] {
        try query("""
            SELECT c.ZISLIKE, c.ZISCAPTION, c.ZISMYCOMMENT, c.ZCOMMENTDATE, c.ZCOMMENTTEXT,
                   c.ZCOMMENTERHASHEDPERSONID, a.ZCLOUDASSETGUID, a.ZDIRECTORY
            FROM ZCLOUDSHAREDCOMMENT c
            LEFT JOIN ZASSET a ON a.Z_PK = COALESCE(c.ZCOMMENTEDASSET, c.ZLIKEDASSET)
            """) { row in
            SharedComment(
                isLike: row.int(0) == 1,
                isCaption: row.int(1) == 1,
                isMine: row.int(2) == 1,
                date: row.isNull(3) ? nil : Format.appleDate(row.double(3)),
                text: row.string(4),
                commenterID: row.string(5),
                assetGUID: row.string(6),
                assetDirectory: row.string(7)
            )
        }
    }
}
