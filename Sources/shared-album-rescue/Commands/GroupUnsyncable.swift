import ArgumentParser
import Foundation
import Photos

/// Gathers assets iCloud couldn't sync (ZCLOUDLOCALSTATE = 4) into a regular album so
/// they can be reviewed and deleted in one place — avoiding the Photos "View" button on
/// the failed-items alert, which can crash. Adding to a *regular* album is permitted by
/// PhotoKit (unlike shared albums).
struct GroupUnsyncable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "group-unsyncable",
        abstract: "Collect assets iCloud couldn't sync into a regular album for review/deletion."
    )

    @OptionGroup var options: LibraryOptions

    @Option(help: "Album title to gather the unsyncable assets into.")
    var album = "SA import dupes — review & delete"

    func run() async throws {
        let state = try options.makeStateStore()
        let db = try PhotosDB.openCopy(of: options.libraryURL, scratchIn: state.tmpDir)
        let uuids = try db.unsyncableUUIDs()
        guard !uuids.isEmpty else {
            print("No unsyncable (cloud state 4) assets found — nothing to group.")
            return
        }
        print("Found \(uuids.count) unsyncable asset(s).")

        try await requirePhotosAccess()

        // PHAsset.localIdentifier is "<UUID>/L0/001"; try the direct fetch, then fall
        // back to a full scan matching the UUID prefix for any that don't resolve.
        let want = Set(uuids)
        var assets: [PHAsset] = []
        var found = Set<String>()
        let direct = PHAsset.fetchAssets(withLocalIdentifiers: uuids.map { "\($0)/L0/001" }, options: nil)
        direct.enumerateObjects { a, _, _ in
            assets.append(a); found.insert(String(a.localIdentifier.prefix(36)))
        }
        if found.count < want.count {
            let all = PHAsset.fetchAssets(with: nil)
            all.enumerateObjects { a, _, _ in
                let u = String(a.localIdentifier.prefix(36))
                if want.contains(u) && !found.contains(u) { assets.append(a); found.insert(u) }
            }
        }
        guard !assets.isEmpty else {
            throw RescueError("Could not resolve any of the \(uuids.count) UUIDs to PHAssets.")
        }

        let collection = try await ensureAlbum(named: album)
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCollectionChangeRequest(for: collection)
            req?.addAssets(assets as NSArray)
        }
        print("✅ Added \(assets.count) of \(uuids.count) unsyncable asset(s) to “\(album)”.")
        if assets.count < uuids.count {
            print("⚠️ \(uuids.count - assets.count) could not be resolved to a PHAsset (may already be gone).")
        }
        print("Open that album in Photos, select all, and delete — that clears the “couldn't sync” error.")
    }
}
