import ArgumentParser
import Foundation
import Photos

struct Download: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fetch cloud-only shared-album items from Apple's servers into the staging area via PhotoKit."
    )

    @OptionGroup var options: LibraryOptions

    @Option(name: .customLong("album"), help: "Limit to this album title (repeatable, case-insensitive).")
    var albumFilters: [String] = []

    @Option(help: "Stop after this many downloads (useful for a first proof-of-concept run).")
    var limit: Int?

    @Flag(help: "Also fetch my own contributions (default: only assets contributed by others).")
    var includeMine = false

    @Flag(help: "Report what would be downloaded without fetching anything.")
    var dryRun = false

    func run() async throws {
        let state = options.stateStore
        let core = ScanCore(library: options.libraryURL, backupLibrary: resolveBackupLibrary(nil), state: state)
        let (_, facts) = try core.gather()
        let persons = PersonDirectory(library: options.libraryURL)
        let filters = Set(albumFilters.map { $0.lowercased() })

        var targets = facts.filter { fact in
            (!fact.asset.isMine || includeMine)
                && !fact.covered
                && (filters.isEmpty || filters.contains(fact.albumTitle.lowercased()))
        }
        targets.sort { ($0.albumTitle, $0.asset.cloudGUID) < ($1.albumTitle, $1.asset.cloudGUID) }
        if let limit { targets = Array(targets.prefix(limit)) }

        let byAlbum = Dictionary(grouping: targets, by: \.albumTitle)
        print("Cloud-only targets: \(targets.count) across \(byAlbum.count) album(s)")
        for (album, items) in byAlbum.sorted(by: { $0.value.count > $1.value.count }) {
            print("  \(Format.pad(album, 40)) \(items.count)")
        }
        if dryRun || targets.isEmpty {
            if dryRun { print("Dry run — nothing fetched.") }
            return
        }

        try await requirePhotosAccess()
        print("Matching assets via PhotoKit…")
        let assetsByUUID = fetchSharedAssetsByUUID()

        var manifest = state.loadManifest()
        var downloaded = 0
        var downloadedBytes: Int64 = 0
        var unmatched = 0
        var failures: [(String, String)] = []

        for fact in targets {
            let asset = fact.asset
            guard let phAsset = assetsByUUID[asset.uuid] else {
                unmatched += 1
                continue
            }
            let resources = PHAssetResource.assetResources(for: phAsset)
            let primaryType: PHAssetResourceType = asset.isVideo ? .video : .photo
            guard let primary = resources.first(where: { $0.type == primaryType }) ?? resources.first else {
                failures.append((asset.cloudGUID, "no resources on PHAsset"))
                continue
            }

            let albumDir = state.stagingDir.appendingPathComponent(Format.slug(fact.albumTitle))
            let ext = (primary.originalFilename as NSString).pathExtension
            let fallbackExt = asset.isVideo ? "mov" : "jpg"
            let destination = albumDir.appendingPathComponent("\(asset.cloudGUID).\(ext.isEmpty ? fallbackExt : ext)")

            do {
                try await writeResource(primary, to: destination)
                var pairedRelative: String?
                if !asset.isVideo, let paired = resources.first(where: { $0.type == .pairedVideo }) {
                    let pairedDestination = albumDir.appendingPathComponent("\(asset.cloudGUID).paired.mov")
                    try await writeResource(paired, to: pairedDestination)
                    pairedRelative = "staging/\(Format.slug(fact.albumTitle))/\(asset.cloudGUID).paired.mov"
                }
                let bytes = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                downloadedBytes += bytes
                manifest[asset.cloudGUID] = StagedItem(
                    guid: asset.cloudGUID,
                    album: fact.albumTitle,
                    albumScopeID: asset.scopeID,
                    stagedPath: "staging/\(Format.slug(fact.albumTitle))/\(destination.lastPathComponent)",
                    pairedVideoPath: pairedRelative,
                    originalFilename: asset.originalFilename ?? primary.originalFilename,
                    captureDate: asset.captureDate,
                    isVideo: asset.isVideo,
                    contributor: persons.name(for: asset.contributorID),
                    source: "download",
                    bytes: bytes
                )
                downloaded += 1
                if downloaded % 25 == 0 {
                    try state.saveManifest(manifest)
                    print("  … \(downloaded)/\(targets.count) downloaded (\(Format.bytes(downloadedBytes)))")
                }
            } catch {
                failures.append((asset.cloudGUID, error.localizedDescription))
            }
        }

        try state.saveManifest(manifest)
        print("""

        ✅ Downloaded \(downloaded) asset(s), \(Format.bytes(downloadedBytes)) → \(state.stagingDir.path)
        """)
        if unmatched > 0 {
            print("⚠️ \(unmatched) asset(s) had no PhotoKit match — open Photos and confirm those shared albums are still listed.")
        }
        if !failures.isEmpty {
            print("❌ \(failures.count) download(s) failed:")
            for (guid, message) in failures.prefix(10) {
                print("   • \(guid) — \(message)")
            }
            throw ExitCode(1)
        }
    }
}
