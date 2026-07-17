import ArgumentParser
import Foundation
import Photos

struct ImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import staged files into the Photos library, into “SA – <album>” albums, with dedup and an idempotent ledger."
    )

    @OptionGroup var options: LibraryOptions

    @Option(help: "Stop after this many imports (useful for a first supervised run).")
    var limit: Int?

    @Flag(help: "Skip the filename+timestamp duplicate check against the library.")
    var force = false

    @Flag(help: "Report what would be imported without changing the library.")
    var dryRun = false

    func run() async throws {
        let state = options.stateStore
        var ledger = state.loadLedger()
        let manifest = state.loadManifest()

        var candidates = manifest.values.filter { ledger[$0.guid] == nil && state.stagedFileExists($0) }
        candidates.sort { ($0.album, $0.guid) < ($1.album, $1.guid) }

        // Layer 2 of dedup (layer 1 is the ledger itself): skip staged items whose
        // original filename + capture second already exist in the library.
        var duplicateSkips: [StagedItem] = []
        if !force {
            let index = try PhotosDB.openCopy(of: options.libraryURL).libraryDedupIndex()
            let (dupes, fresh) = candidates.reduce(into: ([StagedItem](), [StagedItem]())) { acc, item in
                if let name = item.originalFilename, let date = item.captureDate,
                   index.contains(PhotosDB.dedupKey(originalFilename: name, captureDate: date)) {
                    acc.0.append(item)
                } else {
                    acc.1.append(item)
                }
            }
            duplicateSkips = dupes
            candidates = fresh
        }
        if let limit { candidates = Array(candidates.prefix(limit)) }

        let byAlbum = Dictionary(grouping: candidates, by: \.album)
        print("Import plan: \(candidates.count) staged item(s) across \(byAlbum.count) album(s); \(duplicateSkips.count) skipped as already-in-library.")
        for (album, items) in byAlbum.sorted(by: { $0.value.count > $1.value.count }) {
            print("  \(Format.pad("SA – " + album, 44)) \(items.count)")
        }
        if dryRun || candidates.isEmpty {
            if dryRun { print("Dry run — library untouched.") }
            return
        }

        try await requirePhotosAccess()

        // Record duplicate skips in the ledger so scan/verify count them as covered
        // and future runs skip the check.
        for item in duplicateSkips {
            ledger[item.guid] = LedgerEntry(
                guid: item.guid, album: item.album,
                localIdentifier: "already-in-library", importedAt: Date()
            )
        }

        var imported = 0
        var failures: [(String, String)] = []

        for (album, items) in byAlbum.sorted(by: { $0.key < $1.key }) {
            let collection = try await ensureAlbum(named: "SA – \(album)")
            for batch in items.chunked(into: 25) {
                var created: [(StagedItem, String)] = []
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        let albumRequest = PHAssetCollectionChangeRequest(for: collection)
                        var placeholders: [PHObjectPlaceholder] = []
                        for item in batch {
                            let request = PHAssetCreationRequest.forAsset()
                            let creationOptions = PHAssetResourceCreationOptions()
                            if let name = item.originalFilename {
                                creationOptions.originalFilename = name
                            }
                            request.addResource(
                                with: item.isVideo ? .video : .photo,
                                fileURL: state.absoluteURL(forStagedPath: item.stagedPath),
                                options: creationOptions
                            )
                            if let paired = item.pairedVideoPath {
                                request.addResource(
                                    with: .pairedVideo,
                                    fileURL: state.absoluteURL(forStagedPath: paired),
                                    options: PHAssetResourceCreationOptions()
                                )
                            }
                            if let date = item.captureDate {
                                request.creationDate = date
                            }
                            if let placeholder = request.placeholderForCreatedAsset {
                                placeholders.append(placeholder)
                                created.append((item, placeholder.localIdentifier))
                            }
                        }
                        if !placeholders.isEmpty {
                            albumRequest?.addAssets(placeholders as NSArray)
                        }
                    }
                    for (item, localIdentifier) in created {
                        ledger[item.guid] = LedgerEntry(
                            guid: item.guid, album: item.album,
                            localIdentifier: localIdentifier, importedAt: Date()
                        )
                    }
                    imported += created.count
                    try state.saveLedger(ledger)
                    print("  \(album): \(imported) imported so far…")
                } catch {
                    for item in batch {
                        failures.append((item.guid, error.localizedDescription))
                    }
                }
            }
        }

        try state.saveLedger(ledger)
        print("""

        ✅ Imported \(imported) asset(s) into “SA – …” albums; \(duplicateSkips.count) skipped as duplicates.
        Ledger: \(state.root.appendingPathComponent("imported-ledger.json").path)
        Imported items join iCloud Photos and count against its storage. Contributor names live in the staging manifest.
        """)
        if !failures.isEmpty {
            print("❌ \(failures.count) import(s) failed:")
            for (guid, message) in failures.prefix(10) {
                print("   • \(guid) — \(message)")
            }
            throw ExitCode(1)
        }
    }
}
