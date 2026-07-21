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

    @Flag(help: "Skip the filename+timestamp duplicate checks (against the library and within the staged batch).")
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

        // Layer 3: the same photo shared into several albums arrives under distinct
        // cloud GUIDs, so two copies can be new-to-library in the same run and slip
        // past both checks above. Collapse them here: import one copy, ledger the
        // others against it once it lands, and mirror their album membership.
        var batchAliases: [String: [StagedItem]] = [:]
        if !force {
            let collapsed = Self.collapseWithinBatchDuplicates(candidates)
            candidates = collapsed.unique
            batchAliases = collapsed.aliases
            if !batchAliases.isEmpty {
                let count = batchAliases.values.reduce(0) { $0 + $1.count }
                print("↩︎ \(count) staged item(s) duplicate another staged item (same photo in multiple shared albums) — importing one copy each:")
                for (guid, aliases) in batchAliases.sorted(by: { $0.key < $1.key }).prefix(10) {
                    let canonical = candidates.first { $0.guid == guid }
                    let name = canonical?.originalFilename ?? guid
                    let albums = aliases.map { "[\($0.album)]" }.joined(separator: " ")
                    print("   • \(name): keeping [\(canonical?.album ?? "?")] copy; also in \(albums)")
                }
            }
        }
        if let limit { candidates = Array(candidates.prefix(limit)) }

        // Some shared-album items arrive from Apple's servers as JPEG stills wearing
        // video filenames (the album-side video was lost and only its poster frame
        // remains). Photos rejects the extension/content contradiction with error 3302,
        // so normalize everything to an image: image bytes, .JPG staged file, .JPG name.
        var posterOnly: [String] = []
        candidates = candidates.map { item in
            let stagedURL = state.absoluteURL(forStagedPath: item.stagedPath)
            let movieExts = ["mov", "mp4", "m4v"]
            let extLooksVideo = movieExts.contains(stagedURL.pathExtension.lowercased())
                || movieExts.contains(((item.originalFilename ?? "") as NSString).pathExtension.lowercased())
            guard item.isVideo || extLooksVideo, Self.looksLikeImage(stagedURL) else {
                return item
            }
            posterOnly.append("\(item.originalFilename ?? item.guid) [\(item.album)]")
            let fixedURL = stagedURL.deletingPathExtension().appendingPathExtension("JPG")
            if !FileManager.default.fileExists(atPath: fixedURL.path) {
                try? FileManager.default.copyItem(at: stagedURL, to: fixedURL)
            }
            return StagedItem(
                guid: item.guid, album: item.album, albumScopeID: item.albumScopeID,
                stagedPath: (item.stagedPath as NSString).deletingPathExtension + ".JPG",
                pairedVideoPath: nil,
                originalFilename: item.originalFilename.map { ($0 as NSString).deletingPathExtension + ".JPG" },
                captureDate: item.captureDate,
                isVideo: false, contributor: item.contributor,
                source: item.source, bytes: item.bytes
            )
        }
        if !posterOnly.isEmpty {
            print("⚠️ \(posterOnly.count) item(s) carry video filenames but contain still images (the shared album lost the video; only its poster frame survives) — importing the stills:")
            for label in posterOnly.prefix(10) {
                print("   • \(label)")
            }
        }

        let byAlbum = Dictionary(grouping: candidates, by: \.album)
        let collapsedCount = batchAliases.values.reduce(0) { $0 + $1.count }
        print("Import plan: \(candidates.count) staged item(s) across \(byAlbum.count) album(s); \(duplicateSkips.count) skipped as already-in-library; \(collapsedCount) collapsed as within-run duplicates.")
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
        var aliased = 0
        var droppedMotion: [String] = []
        var failures: [(String, String)] = []

        for (album, items) in byAlbum.sorted(by: { $0.key < $1.key }) {
            let collection = try await ensureAlbum(named: "SA – \(album)")
            for batch in items.chunked(into: 25) {
                var created: [(StagedItem, String)] = []
                do {
                    created = try await createAssets(batch, in: collection, state: state, includePaired: true)
                } catch {
                    // performChanges is atomic per batch, so one bad file fails all 25.
                    // Isolate by importing one at a time; a Live Photo whose motion part
                    // fails validation gets a second chance as a plain still.
                    for item in batch {
                        let label = "\(item.originalFilename ?? item.guid) [\(item.album)]"
                        do {
                            created += try await createAssets([item], in: collection, state: state, includePaired: true)
                        } catch where item.pairedVideoPath != nil {
                            do {
                                created += try await createAssets([item], in: collection, state: state, includePaired: false)
                                droppedMotion.append(label)
                            } catch {
                                failures.append((label, "\(error.localizedDescription) (still image alone also failed)"))
                            }
                        } catch {
                            failures.append((label, error.localizedDescription))
                        }
                    }
                }
                for (item, localIdentifier) in created {
                    ledger[item.guid] = LedgerEntry(
                        guid: item.guid, album: item.album,
                        localIdentifier: localIdentifier, importedAt: Date()
                    )
                    // A within-batch duplicate shares the surviving copy's asset; its
                    // own GUID must land in the ledger or the next run re-imports it.
                    for alias in batchAliases[item.guid] ?? [] {
                        ledger[alias.guid] = LedgerEntry(
                            guid: alias.guid, album: alias.album,
                            localIdentifier: localIdentifier, importedAt: Date()
                        )
                        aliased += 1
                    }
                }
                imported += created.count
                try state.saveLedger(ledger)
                // Mirroring runs only after the ledger is on disk: a failure here must
                // never leave an imported asset unrecorded (that is the dup bug itself).
                for (item, localIdentifier) in created {
                    for alias in batchAliases[item.guid] ?? [] where alias.album != item.album {
                        await mirrorIntoAlbum(localIdentifier, album: alias.album)
                    }
                }
                print("  \(album): \(imported) imported so far…")
            }
        }

        try state.saveLedger(ledger)
        print("""

        ✅ Imported \(imported) asset(s) into “SA – …” albums; \(duplicateSkips.count) skipped as duplicates; \(aliased) within-run duplicate(s) ledgered against their surviving copy.
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

    /// Groups candidates whose filename+capture-second collide (±1s, matching the
    /// library index's jitter tolerance). One copy per group survives — the largest,
    /// so a full-resolution copy beats a shared album's re-encode and a surviving
    /// video beats its orphaned poster frame. Returns the survivors in the original
    /// (album, guid) order plus a map from each survivor's GUID to its duplicates.
    static func collapseWithinBatchDuplicates(
        _ candidates: [StagedItem]
    ) -> (unique: [StagedItem], aliases: [String: [StagedItem]]) {
        var groupIndexByKey: [String: Int] = [:]
        var groups: [[StagedItem]] = []
        var unique: [StagedItem] = []
        for item in candidates {
            guard let name = item.originalFilename, let date = item.captureDate else {
                unique.append(item)
                continue
            }
            let neighbors = (-1...1).map {
                PhotosDB.dedupKey(originalFilename: name, captureDate: date, offsetSeconds: $0)
            }
            if let index = neighbors.compactMap({ groupIndexByKey[$0] }).first {
                groups[index].append(item)
            } else {
                groups.append([item])
                groupIndexByKey[neighbors[1]] = groups.count - 1
            }
        }
        var aliases: [String: [StagedItem]] = [:]
        for group in groups {
            let canonical = group.min { a, b in
                a.bytes != b.bytes ? a.bytes > b.bytes : (a.album, a.guid) < (b.album, b.guid)
            }!
            unique.append(canonical)
            if group.count > 1 {
                aliases[canonical.guid] = group.filter { $0.guid != canonical.guid }
            }
        }
        unique.sort { ($0.album, $0.guid) < ($1.album, $1.guid) }
        return (unique, aliases)
    }

    /// Adds an already-imported asset to another “SA – …” album, mirroring a
    /// within-batch duplicate that lived in a second shared album. Never fatal —
    /// the ledger already records the asset, so a retry cannot duplicate it, and
    /// membership can be fixed by hand if this fails.
    private func mirrorIntoAlbum(_ localIdentifier: String, album: String) async {
        do {
            let collection = try await ensureAlbum(named: "SA – \(album)")
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
                throw RescueError("asset \(localIdentifier) not found after import")
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: collection)?.addAssets([asset] as NSArray)
            }
        } catch {
            print("⚠️ Could not mirror duplicate into “SA – \(album)”: \(error.localizedDescription)")
        }
    }

    /// True when the file's magic bytes are a still image (JPEG/PNG/GIF/HEIF family).
    private static func looksLikeImage(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 16), head.count >= 12 else {
            return false
        }
        defer { try? handle.close() }
        if head.prefix(2) == Data([0xFF, 0xD8]) { return true }                       // JPEG
        if head.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) { return true }           // PNG
        if head.prefix(4) == Data([0x47, 0x49, 0x46, 0x38]) { return true }           // GIF
        if head[4..<8] == Data("ftyp".utf8) {
            let brand = String(decoding: head[8..<12], as: UTF8.self)
            return ["heic", "heix", "mif1", "msf1", "avif"].contains(brand)           // HEIF family
        }
        return false
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
