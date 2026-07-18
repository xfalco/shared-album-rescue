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
        let state = try options.makeStateStore()
        var ledger = state.loadLedger()
        let manifest = state.loadManifest()

        var candidates = manifest.values.filter { ledger[$0.guid] == nil && state.stagedFileExists($0) }
        candidates.sort { ($0.album, $0.guid) < ($1.album, $1.guid) }

        // Layer 2 of dedup (layer 1 is the ledger itself): skip staged items whose
        // original filename + capture second already exist in the library.
        var duplicateSkips: [StagedItem] = []
        if !force {
            let index = try PhotosDB.openCopy(of: options.libraryURL, scratchIn: state.tmpDir).libraryDedupIndex()
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
        var droppedMotion: [String] = []
        var failures: [(String, String)] = []

        for (album, items) in byAlbum.sorted(by: { $0.key < $1.key }) {
            let collection = try await ensureAlbum(named: "SA – \(album)")
            for batch in items.chunked(into: 25) {
                do {
                    let created = try await createAssets(batch, in: collection, state: state, includePaired: true)
                    for (item, localIdentifier) in created {
                        ledger[item.guid] = LedgerEntry(
                            guid: item.guid, album: item.album,
                            localIdentifier: localIdentifier, importedAt: Date()
                        )
                    }
                    imported += created.count
                } catch {
                    // performChanges is atomic per batch, so one bad file fails all 25.
                    // Isolate by importing one at a time; a Live Photo whose motion part
                    // fails validation gets a second chance as a plain still.
                    for item in batch {
                        let label = "\(item.originalFilename ?? item.guid) [\(item.album)]"
                        do {
                            let created = try await createAssets([item], in: collection, state: state, includePaired: true)
                            for (created, localIdentifier) in created {
                                ledger[created.guid] = LedgerEntry(
                                    guid: created.guid, album: created.album,
                                    localIdentifier: localIdentifier, importedAt: Date()
                                )
                            }
                            imported += created.count
                        } catch where item.pairedVideoPath != nil {
                            do {
                                let created = try await createAssets([item], in: collection, state: state, includePaired: false)
                                for (created, localIdentifier) in created {
                                    ledger[created.guid] = LedgerEntry(
                                        guid: created.guid, album: created.album,
                                        localIdentifier: localIdentifier, importedAt: Date()
                                    )
                                }
                                imported += created.count
                                droppedMotion.append(label)
                            } catch {
                                failures.append((label, "\(error.localizedDescription) (still image alone also failed)"))
                            }
                        } catch {
                            failures.append((label, error.localizedDescription))
                        }
                    }
                }
                try state.saveLedger(ledger)
                print("  \(album): \(imported) imported so far…")
            }
        }

        try state.saveLedger(ledger)
        print("""

        ✅ Imported \(imported) asset(s) into “SA – …” albums; \(duplicateSkips.count) skipped as duplicates.
        Ledger: \(state.root.appendingPathComponent("imported-ledger.json").path)
        Imported items join iCloud Photos and count against its storage. Contributor names live in the staging manifest.
        """)
        if !droppedMotion.isEmpty {
            print("⚠️ \(droppedMotion.count) Live Photo(s) imported as stills — their motion component failed Photos validation:")
            for label in droppedMotion.prefix(10) {
                print("   • \(label)")
            }
        }
        if !failures.isEmpty {
            print("❌ \(failures.count) import(s) failed:")
            for (label, message) in failures.prefix(15) {
                print("   • \(label) — \(message)")
            }
            throw ExitCode(1)
        }
    }

    /// Creates library assets for the given staged items inside one atomic change
    /// block and returns (item, localIdentifier) pairs for the ledger.
    private func createAssets(
        _ items: [StagedItem],
        in collection: PHAssetCollection,
        state: StateStore,
        includePaired: Bool
    ) async throws -> [(StagedItem, String)] {
        var created: [(StagedItem, String)] = []
        try await PHPhotoLibrary.shared().performChanges {
            let albumRequest = PHAssetCollectionChangeRequest(for: collection)
            var placeholders: [PHObjectPlaceholder] = []
            for item in items {
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
                if includePaired, let paired = item.pairedVideoPath {
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
        if created.count != items.count {
            print("⚠️ \(items.count - created.count) of \(items.count) creation(s) returned no placeholder — they will be retried on the next run")
        }
        return created
    }
}
