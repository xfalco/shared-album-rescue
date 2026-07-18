import Foundation

/// One imported asset, keyed by cloud GUID in the ledger. Once a GUID is here it is
/// never imported again — filenames are re-keyed by Photos migrations, the GUID is not.
struct LedgerEntry: Codable {
    let guid: String
    let album: String
    let localIdentifier: String
    let importedAt: Date
}

/// One staged file, keyed by cloud GUID in the staging manifest.
struct StagedItem: Codable {
    let guid: String
    let album: String
    let albumScopeID: String
    let stagedPath: String        // relative to the state directory
    let pairedVideoPath: String?  // Live Photo motion component, when present
    let originalFilename: String?
    let captureDate: Date?
    let isVideo: Bool
    let contributor: String?
    let source: String            // "live" | "backup" | "download"
    let bytes: Int64
}

struct StateStore {
    let root: URL

    var stagingDir: URL { root.appendingPathComponent("staging") }
    /// Scratch space for temporary Photos.sqlite copies — kept on the state volume so
    /// multi-gigabyte database copies never land on the internal disk.
    var tmpDir: URL { root.appendingPathComponent("tmp") }
    var scanReportURL: URL { root.appendingPathComponent("scan.json") }
    var commentsArchiveURL: URL { root.appendingPathComponent("comments-archive.json") }
    private var ledgerURL: URL { root.appendingPathComponent("imported-ledger.json") }
    private var manifestURL: URL { root.appendingPathComponent("staging-manifest.json") }

    func loadLedger() -> [String: LedgerEntry] { load(ledgerURL) ?? [:] }
    func saveLedger(_ ledger: [String: LedgerEntry]) throws { try save(ledger, to: ledgerURL) }

    func loadManifest() -> [String: StagedItem] { load(manifestURL) ?? [:] }
    func saveManifest(_ manifest: [String: StagedItem]) throws { try save(manifest, to: manifestURL) }

    func stagedFileExists(_ item: StagedItem) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(item.stagedPath).path)
    }

    func absoluteURL(forStagedPath path: String) -> URL {
        root.appendingPathComponent(path)
    }

    private func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try (try encoder.encode(value)).write(to: url, options: .atomic)
    }
}
