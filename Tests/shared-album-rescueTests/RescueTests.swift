import Testing
import Foundation
import SQLite3
@testable import shared_album_rescue

struct FormatTests {
    @Test func slugStripsPathHostileCharacters() {
        #expect(Format.slug("Jojo & Xav Wedding - #Romania") == "Jojo & Xav Wedding - #Romania")
        #expect(Format.slug("a/b:c\\d") == "a-b-c-d")
        #expect(Format.slug("  ") == "untitled")
        #expect(Format.slug("Mango banjo 🥭") == "Mango banjo 🥭")
    }

    @Test func appleEpochConversion() {
        // 2001-01-01 00:00:00 UTC is the Photos reference date.
        #expect(Format.appleDate(0).timeIntervalSince1970 == 978_307_200)
    }
}

struct StateStoreTests {
    @Test func ledgerAndManifestRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sar-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root: root)

        #expect(store.loadLedger().isEmpty)
        try store.saveLedger(["g1": LedgerEntry(guid: "g1", album: "A", localIdentifier: "L1", importedAt: Date())])
        #expect(store.loadLedger()["g1"]?.localIdentifier == "L1")

        let item = StagedItem(
            guid: "g2", album: "A", albumScopeID: "S", stagedPath: "staging/A/g2.jpg",
            pairedVideoPath: nil, originalFilename: "IMG_1.jpg", captureDate: Date(),
            isVideo: false, contributor: "Someone", source: "backup", bytes: 123
        )
        try store.saveManifest(["g2": item])
        #expect(store.loadManifest()["g2"]?.bytes == 123)
        #expect(!store.stagedFileExists(item))
    }
}

/// Pins the SQL column expectations against a minimal fixture database using the
/// schema-5001 shapes documented in PhotosDB.swift.
struct PhotosDBTests {
    private func makeFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sar-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("Photos.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let ddl = """
        CREATE TABLE ZSHARE (Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT, ZSCOPEIDENTIFIER TEXT, ZSTATUS INTEGER, ZSCOPETYPE INTEGER);
        CREATE TABLE ZSHAREPARTICIPANT (Z_PK INTEGER PRIMARY KEY, ZSHARE INTEGER, ZISCURRENTUSER INTEGER, ZROLE INTEGER);
        CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZCLOUDASSETGUID TEXT, ZDIRECTORY TEXT,
            ZFILENAME TEXT, ZCLOUDISMYASSET INTEGER, ZKIND INTEGER, ZWIDTH INTEGER, ZHEIGHT INTEGER,
            ZDURATION REAL, ZLATITUDE REAL, ZDATECREATED REAL, ZCLOUDOWNERHASHEDPERSONID TEXT,
            ZBUNDLESCOPE INTEGER, ZTRASHEDSTATE INTEGER);
        CREATE TABLE ZADDITIONALASSETATTRIBUTES (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZORIGINALFILENAME TEXT);
        CREATE TABLE ZCLOUDSHAREDCOMMENT (Z_PK INTEGER PRIMARY KEY, ZISLIKE INTEGER, ZISCAPTION INTEGER,
            ZISMYCOMMENT INTEGER, ZCOMMENTDATE REAL, ZCOMMENTTEXT TEXT, ZCOMMENTERHASHEDPERSONID TEXT,
            ZCOMMENTEDASSET INTEGER, ZLIKEDASSET INTEGER);
        INSERT INTO ZSHARE VALUES (1, 'Owned Album', 'SCOPE-A', 1, 0);
        INSERT INTO ZSHARE VALUES (2, 'Subscribed Album', 'SCOPE-B', 3, 0);
        INSERT INTO ZSHAREPARTICIPANT VALUES (1, 1, 1, 1);
        INSERT INTO ZSHAREPARTICIPANT VALUES (2, 2, 1, 2);
        INSERT INTO ZASSET VALUES (10, 'UUID-1', 'GUID-1', 'person/SCOPE-A', 'x.JPG', 0, 0, 2048, 1536, 0, -180, 700000000, 'hash1', 2, 0);
        INSERT INTO ZASSET VALUES (11, 'UUID-2', 'GUID-2', 'person/SCOPE-B', 'y.MOV', 1, 1, 1280, 720, 12.5, 45.0, NULL, NULL, 2, 0);
        INSERT INTO ZASSET VALUES (12, 'UUID-3', 'GUID-3', '0', 'lib.HEIC', 0, 0, 4032, 3024, 0, -180, 700000100, NULL, 0, 0);
        INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (1, 10, 'IMG_0001.JPG');
        INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (2, 12, 'IMG_0002.HEIC');
        INSERT INTO ZCLOUDSHAREDCOMMENT VALUES (1, 0, 0, 0, 700000050, 'lovely', 'hash1', 10, NULL);
        INSERT INTO ZCLOUDSHAREDCOMMENT VALUES (2, 1, 0, 1, 700000060, NULL, NULL, NULL, 10);
        """
        #expect(sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK)
        return path
    }

    @Test func queriesReadFixtureSchema() throws {
        let path = try makeFixture()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let db = try PhotosDB(path: path.path)

        let albums = try db.sharedAlbums()
        #expect(albums.count == 2)
        let owned = try #require(albums.first { $0.scopeID == "SCOPE-A" })
        #expect(owned.ownedByMe)
        #expect(!(try #require(albums.first { $0.scopeID == "SCOPE-B" })).ownedByMe)

        let assets = try db.sharedAssets()
        #expect(assets.count == 2)
        let photo = try #require(assets.first { $0.cloudGUID == "GUID-1" })
        #expect(photo.scopeID == "SCOPE-A")
        #expect(photo.originalFilename == "IMG_0001.JPG")
        #expect(!photo.hasLocation)
        #expect(photo.captureDate != nil)
        let video = try #require(assets.first { $0.cloudGUID == "GUID-2" })
        #expect(video.isVideo && video.isMine && video.hasLocation)
        #expect(video.captureDate == nil)

        let index = try db.libraryDedupIndex()
        #expect(index.contains("img_0002.heic|700000100"))
        #expect(index.contains("img_0002.heic|700000099"))
        #expect(!index.contains("img_0001.jpg|700000000"))

        let comments = try db.sharedComments()
        #expect(comments.count == 2)
        #expect(comments.filter(\.isLike).count == 1)
        #expect(comments.first { !$0.isLike }?.assetScopeID == "SCOPE-A")
    }
}
