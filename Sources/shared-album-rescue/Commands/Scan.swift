import ArgumentParser
import Foundation

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inventory every shared-album asset: local, in backup, staged, imported, or cloud-only. Read-only."
    )

    @OptionGroup var options: LibraryOptions

    @Option(help: "Path to an older backup .photoslibrary; adds recoverable-from-backup accounting. Defaults to known Alexandria locations when present.")
    var backupLibrary: String?

    @Flag(help: "Skip probing the default backup-library locations.")
    var noBackup = false

    @Flag(help: "Emit the report as JSON on stdout instead of a table.")
    var json = false

    func run() throws {
        let state = try options.makeStateStore()
        let backup = noBackup ? nil : resolveBackupLibrary(backupLibrary)
        let core = ScanCore(library: options.libraryURL, backupLibrary: backup, state: state)
        let (albums, facts) = try core.gather()
        let report = core.report(albums: albums, facts: facts)

        try state.save(report, to: state.scanReportURL)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print("Library : \(report.libraryPath)")
            print("Backup  : \(report.backupLibraryPath ?? "(none found)")")
            print("Albums  : \(albums.count) shared (\(albums.filter(\.ownedByMe).count) owned by me)\n")
            ScanCore.printTable(report)
            print("\nReport written to \(state.scanReportURL.path)")
        }
    }
}
