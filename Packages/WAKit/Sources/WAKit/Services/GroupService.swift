import Foundation
import GRDB
import os

/// Fills in group names and participant counts with batched overview fetches and loads
/// participants lazily.
public actor GroupService {
    public static let batchSize = 50

    private let bridge: any WaBridgeProtocol
    private let ingest: IngestActor
    /// Pause between overview batches, so a large backlog does not burst IQs at the server.
    private let batchInterval: Duration
    private var filling = false
    private var rerun = false
    private var attempted: Set<String> = []

    public init(bridge: any WaBridgeProtocol, ingest: IngestActor, batchInterval: Duration = .seconds(2)) {
        self.bridge = bridge
        self.ingest = ingest
        self.batchInterval = batchInterval
    }

    /// Fetches subjects and participant counts for group chats missing either, in throttled
    /// batches; each group is asked about once per session unless `stale` names it again (its
    /// membership changed). Safe to call repeatedly: a call during a run schedules one more pass.
    public func fillMissing(stale: [String] = []) async {
        attempted.subtract(stale)
        guard !filling else { rerun = true; return }
        filling = true
        defer { filling = false }
        repeat {
            rerun = false
            await fillPass()
        } while rerun
    }

    public func fillMissingNames() async { await fillMissing() }

    private func fillPass() async {
        do {
            let jids = try await ingest.database.reader.read { db in
                try String.fetchAll(db, sql: """
                    SELECT jid FROM chat WHERE kind = 'group'
                      AND (name IS NULL OR name = '' OR participantCount IS NULL OR participantCount = 0)
                    ORDER BY lastActivityAt DESC
                    """)
            }.filter { !attempted.contains($0) }
            for start in stride(from: 0, to: jids.count, by: Self.batchSize) {
                if start > 0 { try await Task.sleep(for: batchInterval) }
                let batch = Array(jids[start..<min(start + Self.batchSize, jids.count)])
                let groups = try await bridge.fetchGroupOverviews(jids: batch)
                try await ingest.applyGroups(groups)
                // Only an answered batch counts as asked: a failed IQ is retried on the next pass.
                attempted.formUnion(batch)
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
