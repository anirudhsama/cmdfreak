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
    private var joinsDone = false
    private var joinsRunning = false
    /// Loaded this session: one without a join or creation time stays unlisted, and is not
    /// fetched again on every retry.
    private var joinsLoaded: Set<String> = []
    private var membersLoaded: Set<String> = []
    /// Bumped by a membership change, so a fetch that started before it doesn't count as loaded.
    private var membersGeneration: [String: Int] = [:]

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
        membersLoaded.subtract(stale)
        for jid in stale { membersGeneration[jid, default: 0] += 1 }
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

    /// Lists the groups we are in that the chat list does not show (no row, or a row that some
    /// other event created without activity): a join whose notification was lost, or predates
    /// handling it, is otherwise invisible until someone writes. Each is listed at our join time,
    /// so an old, quiet group sorts into history rather than on top. Runs until every group has
    /// loaded once per session; a failed list or group is retried after the next offline sync.
    public func addMissingJoinedGroups() async {
        guard !joinsDone, !joinsRunning else { return }
        joinsRunning = true
        defer { joinsRunning = false }
        do {
            let joined = try await bridge.listParticipatingGroups()
            let listed = try await ingest.database.reader.read { db in
                try Set(String.fetchAll(db, sql: "SELECT jid FROM chat WHERE kind = 'group' AND lastActivityAt IS NOT NULL"))
            }
            var failed = false
            for (i, jid) in joined.filter({ !listed.contains($0) && !joinsLoaded.contains($0) }).enumerated() {
                if i > 0 { try await Task.sleep(for: batchInterval) }
                do {
                    try await loadMetadata(jid: jid)
                    joinsLoaded.insert(jid)
                } catch {
                    failed = true
                    WAKit.log.error("joined group \(jid, privacy: .private) failed: \(error)")
                }
            }
            joinsDone = !failed
        } catch {
            WAKit.log.error("joined groups check failed: \(error)")
        }
    }

    /// Full metadata (participants) for one group; call when the group is opened.
    public func loadMetadata(jid: String) async throws {
        let group = try await bridge.fetchGroupMetadata(jid: jid)
        try await ingest.applyGroups([group])
    }

    /// The group's other members, by name. Participants are fetched once per session, and again after
    /// a membership change; until that succeeds, the people who have written in the group stand in.
    public func members(of groupJid: String) async -> [GroupMember] {
        if !membersLoaded.contains(groupJid) {
            let generation = membersGeneration[groupJid, default: 0]
            do {
                let group = try await bridge.fetchGroupMetadata(jid: groupJid)
                // A membership change during the fetch outdates it; a later fetch has the members.
                if membersGeneration[groupJid, default: 0] == generation {
                    try await ingest.applyGroups([group])
                    if membersGeneration[groupJid, default: 0] == generation { membersLoaded.insert(groupJid) }
                }
            } catch {
                WAKit.log.error("group members \(groupJid, privacy: .private) failed: \(error)")
            }
        }
        do {
            return try await ingest.database.reader.read { try GroupMember.fetchAll($0, group: groupJid) }
        } catch {
            WAKit.log.error("group members read failed: \(error)")
            return []
        }
    }
}

/// Someone a message in a group can mention.
public struct GroupMember: Hashable, Sendable, Identifiable {
    /// The JID a mention lists: the phone-number form when known, else the LID.
    public var jid: String
    public var name: String
    /// "+<digits>" when the phone number is known.
    public var phone: String?
    public var hasAvatar: Bool

    public var id: String { jid }
    public var avatarURL: URL? { hasAvatar ? AvatarService.fileURL(for: jid) : nil }

    public init(jid: String, name: String, phone: String? = nil, hasAvatar: Bool = false) {
        self.jid = jid
        self.name = name
        self.phone = phone
        self.hasAvatar = hasAvatar
    }

    /// Named as their mentions are (see `Mentions.Resolver`), else by their latest push name here.
    static func fetchAll(_ db: Database, group: String) throws -> [GroupMember] {
        var jids = try String.fetchAll(db, sql: "SELECT jid FROM group_participant WHERE groupJid = ?", arguments: [group])
        if jids.isEmpty {
            jids = try String.fetchAll(db, sql: "SELECT DISTINCT senderJid FROM message WHERE chatJid = ? AND fromMe = 0 AND senderJid != ''",
                                       arguments: [group])
        }
        let pushNames = Dictionary(try Row.fetchAll(db, sql: """
            SELECT senderJid, pushName FROM message WHERE chatJid = ? AND fromMe = 0 AND pushName IS NOT NULL AND pushName != ''
            ORDER BY sortKey
            """, arguments: [group]).map { ($0["senderJid"] as String, $0["pushName"] as String) }, uniquingKeysWith: { _, b in b })
        var resolver = try Mentions.Resolver(db)
        var seen: Set<String> = []
        var out: [GroupMember] = []
        for jid in jids {
            let mention = try resolver.mention(of: jid)
            // Ourselves: never offered.
            if mention != nil, mention?.jid == nil { continue }
            let target = mention?.jid ?? Mentions.Resolver.bare(jid)
            guard seen.insert(target).inserted else { continue }
            let name = mention?.name ?? pushNames[jid] ?? JID.user(jid)
            out.append(GroupMember(jid: target, name: name, phone: mention?.phone))
        }
        let avatars = try Set(String.fetchAll(db, sql: "SELECT jid FROM contact WHERE hasAvatar AND jid IN (\(placeholders(out.count)))",
                                              arguments: StatementArguments(out.map(\.jid))))
        for i in out.indices { out[i].hasAvatar = avatars.contains(out[i].jid) }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
