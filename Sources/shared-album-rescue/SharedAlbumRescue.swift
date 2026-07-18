import ArgumentParser
import Foundation

@main
struct SharedAlbumRescue: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shared-album-rescue",
        abstract: "Inventory, stage, and import iCloud Shared Album content that only exists in Apple's cloud or in old backups.",
        version: "0.1.0",
        subcommands: [
            Scan.self,
            Rescue.self,
            Download.self,
            ImportCommand.self,
            ArchiveComments.self,
            Verify.self,
        ],
        defaultSubcommand: Scan.self
    )
}

struct RescueError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Options shared by every subcommand. Defaults are this machine's real paths —
/// this is a personal tool in the spirit of BackupManager's BackupConfiguration.
struct LibraryOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the live Photos library (.photoslibrary).")
    var library: String = "/Volumes/SecondLifeSSD/second_life_data/xav/Photos Library.photoslibrary"

    @Option(name: .long, help: """
    Directory holding everything the tool writes: the staging area downloads land in, scan \
    reports, the import ledger, and temporary database copies. Defaults to the SecondLifeSSD \
    drive so nothing bulky touches the internal disk.
    """)
    var state: String = "/Volumes/SecondLifeSSD/second_life_data/xav/SharedAlbumRescue"

    var libraryURL: URL { URL(fileURLWithPath: library) }

    /// Validates that the state directory sits on a real mounted volume before anything
    /// writes to it: with the drive unplugged, a /Volumes/<name> path would silently
    /// become a plain folder on the internal disk and fill it — the exact accident the
    /// external state location exists to avoid.
    func makeStateStore() throws -> StateStore {
        let root = URL(fileURLWithPath: state).standardizedFileURL
        if state.hasPrefix("/Volumes/") {
            let components = root.pathComponents
            guard components.count > 2 else {
                throw RescueError("--state must point inside a volume, got \(state)")
            }
            let volume = URL(fileURLWithPath: "/Volumes").appendingPathComponent(components[2])
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: volume.path, isDirectory: &isDirectory)
            let volumeRoot = (try? volume.resourceValues(forKeys: [.volumeURLKey]))?.volume
            guard exists, isDirectory.boolValue,
                  volumeRoot?.standardizedFileURL.path == volume.standardizedFileURL.path else {
                throw RescueError("State volume \(volume.path) is not mounted — connect the drive or pass --state.")
            }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StateStore(root: root)
    }
}

/// Known locations of the pre-migration backup library that still holds shared-album
/// files evicted from the live library (checked in order).
let defaultBackupLibraryCandidates = [
    "/Volumes/Alexandria/second_life_data/xav/Photos/Photos Library.2025-12-13.photoslibrary",
    "/Volumes/Alexandria/second_life_data/xav/Photos/Photos Library.photoslibrary",
]

func resolveBackupLibrary(_ explicit: String?) -> URL? {
    if let explicit {
        return URL(fileURLWithPath: explicit)
    }
    for candidate in defaultBackupLibraryCandidates
    where FileManager.default.fileExists(atPath: candidate) {
        return URL(fileURLWithPath: candidate)
    }
    return nil
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Photos stores dates as seconds since 2001-01-01 (Apple reference date).
    static func appleDate(_ seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Album titles become staging directory names; strip path-hostile characters.
    static func slug(_ title: String) -> String {
        let hostile = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { hostile.contains($0) ? Character("-") : Character($0) }
        let result = String(cleaned).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "untitled" : result
    }

    static func pad(_ text: String, _ width: Int, alignRight: Bool = false) -> String {
        let count = text.count
        guard count < width else { return String(text.prefix(width)) }
        let padding = String(repeating: " ", count: width - count)
        return alignRight ? padding + text : text + padding
    }
}
