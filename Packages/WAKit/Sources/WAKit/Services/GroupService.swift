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
    private var reconciledJoins = false

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

    /// Adds the groups we are in but have no chat for: a join whose notification was lost (or
    /// predates handling it) is otherwise invisible until someone writes. Once per session; each
    /// is listed at our join time, so an old, quiet group sorts into history rather than on top.
    public func addMissingJoinedGroups() async {
        guard !reconciledJoins else { return }
        do {
            let joined = try await bridge.listParticipatingGroups()
            let known = try await ingest.database.reader.read { db in
                try Set(String.fetchAll(db, sql: "SELECT jid FROM chat WHERE kind = 'group'"))
            }
            reconciledJoins = true
            for (i, jid) in joined.filter({ !known.contains($0) }).enumerated() {
                if i > 0 { try await Task.sleep(for: batchInterval) }
                do {
                    try await loadMetadata(jid: jid)
                } catch {
                    WAKit.log.error("joined group \(jid, privacy: .private) failed: \(error)")
                }
            }
        } catch {
            WAKit.log.error("joined groups check failed: \(error)")
        }
    }

    /// Full metadata (participants) for one group; call when the group is opened.
    public func loadMetadata(jid: String) async throws {
        let group = try await bridge.fetchGroupMetadata(jid: jid)
        try await ingest.applyGroups([group])
    }
}

/// Lazily downloads profile pictures into `~/Library/Caches/CmdFreak/avatars/` and records that one
/// exists on the chat and, for a person, on their contact row. Checks each JID at most once per
/// `recheckInterval`.
public actor AvatarService {
    public static var defaultRoot: URL {
        WAKit.cacheDirectory.appending(path: "avatars", directoryHint: .isDirectory)
    }

    /// Where the app's avatar for `jid` lives. `root` is only overridden by tests.
    public nonisolated static func fileURL(for jid: String) -> URL {
        defaultRoot.appending(path: fileName(for: jid))
    }

    public let root: URL
    public let recheckInterval: Int64
    private let bridge: any WaBridgeProtocol
    private let ingest: IngestActor
    private var inFlight: [String: Task<URL?, Never>] = [:]
    /// After the server rate-limits a lookup, none are made until then (the rest of a batch included).
    private var backoffUntil: Int64 = 0
    static let rateLimitBackoff: Int64 = 300

    public init(bridge: any WaBridgeProtocol, ingest: IngestActor, root: URL = AvatarService.defaultRoot, recheckInterval: Int64 = 86_400) {
        self.bridge = bridge
        self.ingest = ingest
        self.root = root
        self.recheckInterval = recheckInterval
    }

    /// The cached avatar for `jid`, fetching it if it has not been checked recently. A LID whose phone
    /// number is known resolves to the phone number's file. `commonGroup`, a group shared with the
    /// person, lets the server answer for people we hold no privacy token for; without one, any group
    /// they are known to be in is used.
    public func avatar(for jid: String, commonGroup: String? = nil) async -> URL? {
        let jid = await ingest.canonicalJid(jid)
        if let task = inFlight[jid] { return await task.value }
        typealias Check = (hasAvatar: Bool, checkedAt: Int64?)
        let read = try? await ingest.database.reader.read { db -> (chat: Check?, contact: Check?, group: String?) in
            let check = { (table: String) throws -> Check? in
                try Row.fetchOne(db, sql: "SELECT hasAvatar, avatarCheckedAt FROM \(table) WHERE jid = ?", arguments: [jid])
                    .map { ($0["hasAvatar"], $0["avatarCheckedAt"]) }
            }
            let group = try commonGroup
                ?? String.fetchOne(db, sql: "SELECT groupJid FROM group_participant WHERE jid = ? LIMIT 1", arguments: [jid])
            return (try check("chat"), try check("contact"), group)
        }
        // The chat's record is what the chat list shows, so it decides when there is one; a chat never
        // checked takes its contact's (checked through a group), copied over so the list shows it too.
        var checked = read?.chat ?? read?.contact
        if let chat = read?.chat, chat.checkedAt == nil, let contact = read?.contact, let at = contact.checkedAt {
            checked = contact
            try? await ingest.setAvatar(jid: jid, present: contact.hasAvatar, checkedAt: at)
        }
        let dest = root.appending(path: Self.fileName(for: jid))
        let hasAvatar = checked?.hasAvatar ?? false
        if hasAvatar, FileManager.default.fileExists(atPath: dest.path) { return dest }
        // A recorded avatar whose file is gone (Caches purged) is fetched again right away.
        let now = Int64(Date().timeIntervalSince1970)
        if !hasAvatar, let checkedAt = checked?.checkedAt, now - checkedAt < recheckInterval { return nil }
        guard now >= backoffUntil else { return nil }
        // Another call may have started the fetch while this one read the database.
        if let task = inFlight[jid] { return await task.value }

        let bridge = self.bridge, ingest = self.ingest, root = self.root, group = read?.group
        let task = Task<URL?, Never> {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let has = try await bridge.profilePicture(jid: jid, commonGid: group, preview: true, destPath: dest.path)
                // A removed or hidden picture must not keep showing from the old file.
                if !has { try? FileManager.default.removeItem(at: dest) }
                try await ingest.setAvatar(jid: jid, present: has, checkedAt: now)
                return has ? dest : nil
            } catch BridgeError.RateLimited {
                backoffUntil = now + Self.rateLimitBackoff
                return nil
            } catch {
                WAKit.log.debug("avatar \(jid, privacy: .private) failed: \(error)")
                return nil
            }
        }
        inFlight[jid] = task
        defer { inFlight[jid] = nil }
        return await task.value
    }

    nonisolated static func fileName(for jid: String) -> String {
        jid.replacingOccurrences(of: "/", with: "_") + ".jpg"
    }
}
