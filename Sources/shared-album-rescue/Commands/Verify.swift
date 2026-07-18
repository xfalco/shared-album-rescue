import ArgumentParser
import Foundation

struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Exit non-zero if any asset contributed by others is still cloud-only (no local, backup, staged, or imported copy)."
    )

    @OptionGroup var options: LibraryOptions

    @Option(help: "Path to an older backup .photoslibrary to count as coverage.")
    var backupLibrary: String?

    func run() throws {
        let state = try options.makeStateStore()
        let backup = resolveBackupLibrary(backupLibrary)
        let core = ScanCore(library: options.libraryURL, backupLibrary: backup, state: state)
        let (albums, facts) = try core.gather()
        let report = core.report(albums: albums, facts: facts)
        let uncovered = report.totals.othersCloudOnly

        if uncovered == 0 {
            print("✅ All \(report.totals.others) others' shared assets have a copy under your control.")
            return
        }

        print("❌ \(uncovered) of \(report.totals.others) others' shared assets are cloud-only. Worst albums:")
        for album in report.albums.filter({ $0.othersCloudOnly > 0 }).prefix(10) {
            print("   \(Format.pad(album.title, 40)) \(album.othersCloudOnly) cloud-only")
        }
        print("Run `shared-album-rescue rescue` (old backups) and `shared-album-rescue download` (Apple servers) to secure them.")
        throw ExitCode(1)
    }
}
