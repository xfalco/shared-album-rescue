import ArgumentParser
import Foundation

struct ArchiveComments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive-comments",
        abstract: "Archive shared-album comments, likes, and captions to JSON — they exist only inside Photos.sqlite."
    )

    @OptionGroup var options: LibraryOptions

    struct CommentRecord: Codable {
        let album: String
        let assetGUID: String?
        let kind: String        // "comment" | "like" | "caption"
        let text: String?
        let author: String?
        let authorIsMe: Bool
        let date: Date?
    }

    func run() throws {
        let db = try PhotosDB.openCopy(of: options.libraryURL)
        let albums = try db.sharedAlbums()
        let albumsByScope = Dictionary(albums.map { ($0.scopeID, $0.title) }, uniquingKeysWith: { first, _ in first })
        let persons = PersonDirectory(library: options.libraryURL)

        let records = try db.sharedComments().map { comment -> CommentRecord in
            CommentRecord(
                album: comment.assetScopeID.flatMap { albumsByScope[$0] } ?? "(unknown album)",
                assetGUID: comment.assetGUID,
                kind: comment.isLike ? "like" : (comment.isCaption ? "caption" : "comment"),
                text: comment.text,
                author: persons.name(for: comment.commenterID) ?? (comment.isMine ? "me" : nil),
                authorIsMe: comment.isMine,
                date: comment.date
            )
        }

        let state = options.stateStore
        try state.save(records, to: state.commentsArchiveURL)

        let likes = records.filter { $0.kind == "like" }.count
        let captions = records.filter { $0.kind == "caption" }.count
        let comments = records.count - likes - captions
        let authors = Set(records.compactMap(\.author)).count
        print("""
        ✅ Archived \(records.count) records → \(state.commentsArchiveURL.path)
           \(comments) comments, \(likes) likes, \(captions) captions, \(authors) distinct authors
        """)
    }
}
