import ArgumentParser
import Foundation

struct Rescue: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy every reachable shared-album file (live cache + old backup) into the staging area, keyed by cloud GUID."
    )

    @OptionGroup var options: LibraryOptions

    @Option(help: "Path to an older backup .photoslibrary. Defaults to known Alexandria locations when present.")
    var backupLibrary: String?

    @Flag(help: "Also stage my own contributions (default: only assets contributed by others).")
    var includeMine = false

    @Flag(help: "Report what would be staged without copying anything.")
    var dryRun = false

    func run() throws {
        guard let backup = resolveBackupLibrary(backupLibrary) else {
            print("⚠️ No backup library found — staging from the live cache only.")
            try stage(backup: nil)
            return
        }
        try stage(backup: backup)
    }

    private func stage(backup: URL?) throws {
        let state = options.stateStore
        let core = ScanCore(library: options.libraryURL, backupLibrary: backup, state: state)
        let (_, facts) = try core.gather()
        let persons = PersonDirectory(library: options.libraryURL)
        let fm = FileManager.default

        let eligible = facts.filter { !$0.asset.isMine || includeMine }
        let targets = eligible.filter { !$0.imported && !$0.staged && ($0.localFile ?? $0.backupFile) != nil }
        let alreadySecured = eligible.filter { $0.imported || $0.staged }.count
        let cloudOnly = eligible.filter { !$0.covered }.count
        let fromLive = targets.filter { $0.localFile != nil }.count

        print("""
        Staging plan (\(includeMine ? "all contributors" : "others' contributions only")):
          to stage from live cache : \(fromLive)
          to stage from backup     : \(targets.count - fromLive)
          already staged/imported  : \(alreadySecured)
          cloud-only (need `download`): \(cloudOnly)
        """)
        if dryRun {
            print("Dry run — nothing copied.")
            return
        }

        var manifest = state.loadManifest()
        var staged = 0
        var stagedBytes: Int64 = 0
        var failures: [(String, String)] = []

        for fact in targets {
            // Prefer the live cache copy; both are the same shared-size content for a GUID.
            guard let source = fact.localFile ?? fact.backupFile else { continue }
            let asset = fact.asset
            let albumDir = state.stagingDir.appendingPathComponent(Format.slug(fact.albumTitle))
            let ext = source.pathExtension
            let destination = albumDir.appendingPathComponent(ext.isEmpty ? asset.cloudGUID : "\(asset.cloudGUID).\(ext)")

            do {
                try fm.createDirectory(at: albumDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: source, to: destination)

                // Live Photos ship as a still plus a paired motion file alongside it.
                var pairedRelative: String?
                if !asset.isVideo {
                    let stem = source.deletingPathExtension()
                    for pairedExt in ["MOV", "mov"] {
                        let paired = stem.appendingPathExtension(pairedExt)
                        if fm.fileExists(atPath: paired.path) {
                            let pairedDest = albumDir.appendingPathComponent("\(asset.cloudGUID).paired.\(pairedExt)")
                            if fm.fileExists(atPath: pairedDest.path) {
                                try fm.removeItem(at: pairedDest)
                            }
                            try fm.copyItem(at: paired, to: pairedDest)
                            pairedRelative = relative(pairedDest, to: state.root)
                            break
                        }
                    }
                }

                let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                stagedBytes += Int64(bytes)
                manifest[asset.cloudGUID] = StagedItem(
                    guid: asset.cloudGUID,
                    album: fact.albumTitle,
                    albumScopeID: asset.scopeID,
                    stagedPath: relative(destination, to: state.root),
                    pairedVideoPath: pairedRelative,
                    originalFilename: asset.originalFilename,
                    captureDate: asset.captureDate,
                    isVideo: asset.isVideo,
                    contributor: persons.name(for: asset.contributorID),
                    source: fact.localFile != nil ? "live" : "backup",
                    bytes: Int64(bytes)
                )
                staged += 1
                if staged % 200 == 0 {
                    try state.saveManifest(manifest)
                    print("  … \(staged)/\(targets.count) staged (\(Format.bytes(stagedBytes)))")
                }
            } catch {
                failures.append((source.path, error.localizedDescription))
            }
        }

        try state.saveManifest(manifest)

        print("""

        ✅ Staged \(staged) file(s), \(Format.bytes(stagedBytes)) → \(state.stagingDir.path)
        Manifest: \(state.root.appendingPathComponent("staging-manifest.json").path)
        """)
        if cloudOnly > 0 {
            print("☁️ \(cloudOnly) asset(s) remain cloud-only — run `shared-album-rescue download` to fetch them from Apple.")
        }
        if !failures.isEmpty {
            print("❌ \(failures.count) file(s) failed:")
            for (path, message) in failures.prefix(10) {
                print("   • \(path) — \(message)")
            }
            throw ExitCode(1)
        }
    }

    private func relative(_ url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
    }
}
