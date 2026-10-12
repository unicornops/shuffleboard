import Foundation

// MARK: - BoardCacheSnapshot

/// The copy of an account's boards kept on the Mac (#156), so the app opens straight away and can show them
/// read-only when the server can't be reached. It holds what the server sent (boards with their labels and members,
/// and the lists and cards of the boards that were opened) and never any credentials.
struct BoardCacheSnapshot: Codable, Sendable {
    /// The lists and cards of one board, and when they came from the server.
    struct Lists: Codable, Sendable {
        var stacks: [Stack]
        var syncedAt: Date
    }

    /// Bumped when the format changes; a copy in another format is ignored, and replaced on the next load.
    static let currentVersion = 1

    var version = Self.currentVersion
    var boards: [Board] = []
    /// When `boards` last came from the server; nil before they have.
    var boardsSyncedAt: Date?
    /// The board that was open, to open again at launch.
    var selectedBoardId: Int?
    /// By board id.
    var lists: [Int: Lists] = [:]
}

// MARK: - BoardCacheStore

/// Where `BoardCacheSnapshot`s are kept: files in Application Support in the app, memory in tests.
protocol BoardCacheStore: AnyObject {
    /// `accountId`'s copy, or nil if there is none or it can't be read.
    func load(accountId: Account.ID) -> BoardCacheSnapshot?
    func save(_ snapshot: BoardCacheSnapshot, accountId: Account.ID)
    /// Deletes `accountId`'s copy, as when signing out.
    func remove(accountId: Account.ID)
}

/// One JSON file per account in `directory`: by default `Boards` in the app's Application Support folder (inside
/// its sandbox container). Readable only by the user, and left out of backups, as it can be downloaded again.
final class FileBoardCacheStore: BoardCacheStore {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The store in the app's Application Support folder; nil if there is none.
    static func standard() -> FileBoardCacheStore? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return support.map { FileBoardCacheStore(directory: $0.appendingPathComponent("Boards", isDirectory: true)) }
    }

    /// The file for `accountId`. Account ids contain characters such as `/` and `:`, so the name is the id in
    /// URL-safe base64.
    func fileURL(accountId: Account.ID) -> URL {
        let name = Data(accountId.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    func load(accountId: Account.ID) -> BoardCacheSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(accountId: accountId)),
              let snapshot = try? Self.decoder.decode(BoardCacheSnapshot.self, from: data),
              snapshot.version == BoardCacheSnapshot.currentVersion else { return nil }
        return snapshot
    }

    func save(_ snapshot: BoardCacheSnapshot, accountId: Account.ID) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var url = fileURL(accountId: accountId)
            try Self.encoder.encode(snapshot).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            // Not worth bothering the user about: the copy is only a convenience, and the next save tries again.
        }
    }

    func remove(accountId: Account.ID) {
        try? FileManager.default.removeItem(at: fileURL(accountId: accountId))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
