import Foundation
import GRDB
import os

/// Fills in group names with batched overview fetches and loads participants lazily.
public actor GroupService {
    public static let batchSize = 50

    private let bridge: any WaBridgeProtocol
    private let ingest: IngestActor
    private var filling = false
    private var attempted: Set<String> = []

    public init(bridge: any WaBridgeProtocol, ingest: IngestActor) {
        self.bridge = bridge
        self.ingest = ingest
    }

    /// Fetches subjects for group chats that have no name yet, in batches. Safe to call repeatedly.
    public func fillMissingNames() async {
        guard !filling else { return }
        filling = true
        defer { filling = false }
        do {
            let jids = try await ingest.database.reader.read { db in
                try String.fetchAll(db, sql: "SELECT jid FROM chat WHERE kind = 'group' AND (name IS NULL OR name = '')")
            }.filter { !attempted.contains($0) }
            for start in stride(from: 0, to: jids.count, by: Self.batchSize) {
                let batch = Array(jids[start..<min(start + Self.batchSize, jids.count)])
                attempted.formUnion(batch)
                let groups = try await bridge.fetchGroupOverviews(jids: batch)
                try await ingest.applyGroups(groups)
            }
        } catch {
            WAKit.log.error("group overviews failed: \(error)")
        }
    }

    /// Full metadata (participants) for one group; call when the group is opened.
    public func loadMetadata(jid: String) async throws {
        let group = try await bridge.fetchGroupMetadata(jid: jid)
        try await ingest.applyGroups([group])
    }
}

/// Lazily downloads profile pictures into `~/Library/Caches/BetterWA/avatars/` and records the
/// path on the chat. Checks each JID at most once per `recheckInterval`.
public actor AvatarService {
    public static var defaultRoot: URL {
        URL.cachesDirectory.appending(path: "BetterWA/avatars", directoryHint: .isDirectory)
    }

    public let root: URL
    public let recheckInterval: Int64
    private let bridge: any WaBridgeProtocol
    private let ingest: IngestActor
    private var inFlight: [String: Task<URL?, Never>] = [:]

    public init(bridge: any WaBridgeProtocol, ingest: IngestActor, root: URL = AvatarService.defaultRoot, recheckInterval: Int64 = 86_400) {
        self.bridge = bridge
        self.ingest = ingest
        self.root = root
        self.recheckInterval = recheckInterval
    }

    /// The cached avatar for `jid`, fetching it if it has not been checked recently.
    public func avatar(for jid: String) async -> URL? {
        if let task = inFlight[jid] { return await task.value }
        let chat = try? await ingest.database.reader.read { db in try ChatRecord.fetchOne(db, key: jid) }
        let path = chat?.avatarPath
        let checkedAt = chat?.avatarCheckedAt
        if let path, FileManager.default.fileExists(atPath: path) { return URL(filePath: path) }
        let now = Int64(Date().timeIntervalSince1970)
        if let checkedAt, now - checkedAt < recheckInterval { return nil }

        let dest = root.appending(path: Self.fileName(for: jid))
        let bridge = self.bridge, ingest = self.ingest, root = self.root
        let task = Task<URL?, Never> {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let has = try await bridge.profilePicture(jid: jid, preview: true, destPath: dest.path)
                try await ingest.setAvatar(jid: jid, path: has ? dest.path : nil, checkedAt: now)
                return has ? dest : nil
            } catch {
                WAKit.log.debug("avatar \(jid, privacy: .private) failed: \(error)")
                return nil
            }
        }
        inFlight[jid] = task
        defer { inFlight[jid] = nil }
        return await task.value
    }

    static func fileName(for jid: String) -> String {
        jid.replacingOccurrences(of: "/", with: "_") + ".jpg"
    }
}
