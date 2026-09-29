import CryptoKit
import Dispatch
import Foundation
import GRDB
import os

/// A mutation of a message that may arrive before the message itself; parked in `pending_mutation`.
enum MessageMutation: Codable, Hashable, Sendable {
    case edit(text: String?, editedAt: Int64)
    case revoke(timestamp: Int64)
    case reaction(senderJid: String, fromMe: Bool, emoji: String, timestamp: Int64)
    case pollVote(voterJid: String, selected: [String], timestamp: Int64)
    case status(rank: Int)
    /// An encrypted edit or poll vote whose parent secret the bridge lacked; retried through
    /// `WaBridge.decryptParked` once the target is stored.
    case encrypted(envelope: Data)
}

/// A parked encrypted add-on whose target has been stored; `retryParked` decrypts and applies it.
public struct ParkedEnvelope: Sendable, Hashable {
    let rowId: Int64
    let envelope: Data
}

/// What one applied batch leaves for the caller to do after commit.
struct IngestResult {
    /// Incoming messages read in the focused chat (per chat) to mark read.
    var reads: [String: [BridgeMessageKey]] = [:]
    /// Encrypted add-ons whose target arrived in this batch.
    var parked: [ParkedEnvelope] = []
    /// Also yielded on `IngestActor.notices`.
    var notices: [NoticeEvent] = []
}

/// Changes accumulated during one write transaction, published to the feed after commit.
struct ChangeSet {
    var added: [String: [String]] = [:]
    var updated: [String: Set<String>] = [:]
    var deleted: [String: [String]] = [:]
    var replaced: [String: [(old: String, new: String)]] = [:]
    var reload: Set<String> = []
    /// Chats whose last-message preview must be recomputed before commit.
    var dirty: Set<String> = []
    var pushNames: [String: String] = [:]
    /// Incoming live messages that landed in the focused chat: not counted unread, so the caller
    /// sends read receipts for them after commit.
    var readWhileFocused: [String: [BridgeMessageKey]] = [:]
    var parked: [ParkedEnvelope] = []
    /// Group chats where a reported own participant arrived for an existing row.
    var participantEvidence: Set<String> = []
    /// Chat → its newest incoming live message that may alert; resolved into `notices` at commit.
    /// `timestamp` is when it became readable: the send time, or now for a decrypted placeholder.
    var alerts: [String: (id: String, timestamp: Int64)] = [:]
    /// Retractions (read, removed), published before this batch's incoming notices.
    var notices: [NoticeEvent] = []

    /// Keeps the newest candidate per chat, whatever order the batch delivers them in.
    mutating func alert(_ chat: String, _ id: String, _ timestamp: Int64) {
        if let current = alerts[chat], current.timestamp > timestamp { return }
        alerts[chat] = (id, timestamp)
    }

    mutating func chatRead(_ chat: String) {
        alerts[chat] = nil
        notices.append(.chatRead(chat))
    }

    mutating func removed(_ chat: String, _ id: String) {
        if alerts[chat]?.id == id { alerts[chat] = nil }
        notices.append(.messageRemoved(chatJid: chat, messageId: id))
    }

    mutating func add(_ chat: String, _ id: String) { added[chat, default: []].append(id); dirty.insert(chat) }
    mutating func update(_ chat: String, _ id: String) { updated[chat, default: []].insert(id); dirty.insert(chat) }
    mutating func delete(_ chat: String, _ id: String) { deleted[chat, default: []].append(id); dirty.insert(chat) }

    var touchedChats: Set<String> {
        Set(added.keys).union(updated.keys).union(deleted.keys).union(replaced.keys).union(reload)
    }
}

public struct OpenChatResult: Sendable {
    /// Unread incoming messages to pass to `WaBridge.markRead`.
    public var unreadKeys: [BridgeMessageKey]
    /// The chat was marked unread; the caller should sync `markChatRead(read: true)`.
    public var wasMarkedUnread: Bool
}

/// The single writer. Each bridge batch is one transaction; chat aggregates are updated in the
/// same transaction; `MessageChange`s are published per chat after commit.
public actor IngestActor {
    public nonisolated let database: AppDatabase
    public nonisolated let feed: MessageChangeFeed
    public nonisolated let focus: ChatFocus
    /// Notification events after each commit. Single consumer.
    public nonisolated let notices: AsyncStream<NoticeEvent>
    private nonisolated let noticesContinuation: AsyncStream<NoticeEvent>.Continuation

    private nonisolated let queue = DispatchSerialQueue(label: "\(WAKit.subsystem).ingest", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// LID → phone-number JID.
    private var aliases: [String: String]
    private var ingestSeq: Int64
    private var persistedSeq: Int64
    private var pendingCount: Int
    /// Delete-for-me tombstones exist (skips the per-insert lookup while there are none).
    private var hasMessageTombstones: Bool

    static let maxAddsBeforeReload = 300
    /// Older incoming messages (an offline backlog after sleep) arrive silently.
    static let maxAlertAge: Int64 = 120

    public init(database: AppDatabase, feed: MessageChangeFeed = MessageChangeFeed(), focus: ChatFocus = ChatFocus()) throws {
        self.database = database
        self.feed = feed
        self.focus = focus
        (notices, noticesContinuation) = AsyncStream<NoticeEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let (aliases, seq, pending, tombstones) = try database.pool.read { db in
            let a = try JidAliasRecord.fetchAll(db)
            let s = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'ingestSeq'").flatMap { Int64($0) } ?? 0
            let p = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_mutation") ?? 0
            let t = try Bool.fetchOne(db, sql: "SELECT 1 FROM tombstone WHERE kind = 'message' LIMIT 1") ?? false
            return (Dictionary(a.map { ($0.lid, $0.pn) }, uniquingKeysWith: { _, b in b }), s, p, t)
        }
        self.aliases = aliases
        self.ingestSeq = seq
        self.persistedSeq = seq
        self.pendingCount = pending
        self.hasMessageTombstones = tombstones
    }

    // MARK: - Public entry points

    /// Applies one bridge batch in a single transaction. Session-only events are ignored here.
    public func apply(_ events: [BridgeEvent]) throws {
        _ = try applyBatch(events)
    }

    /// `apply`, returning what the caller does after commit (read receipts, parked add-ons to decrypt).
    func applyBatch(_ events: [BridgeEvent]) throws -> IngestResult {
        try perform { db, cs in
            for event in events { try self.handle(event, db, &cs) }
            return IngestResult(reads: cs.readWhileFocused, parked: cs.parked)
        } after: { result, cs in
            result.notices = cs.notices
        }
    }

    /// Decrypts parked add-ons (`decrypt` is `WaBridge.decryptParked`) and applies the ones that
    /// opened, returning their row ids; the rest stay parked for `ParkedRetrier` or until pruned.
    @discardableResult
    public func retryParked(_ parked: [ParkedEnvelope], decrypt: @Sendable ([Data]) async -> [BridgeMessageUpdate?]) async throws -> Set<Int64> {
        guard !parked.isEmpty else { return [] }
        let results = await decrypt(parked.map(\.envelope))
        let opened = zip(parked, results).compactMap { p, u -> (Int64, BridgeMessageUpdate)? in
            guard let u, !u.isEncrypted else { return nil }
            return (p.rowId, u)
        }
        guard !opened.isEmpty else { return [] }
        try perform { db, cs in
            for (rowId, update) in opened {
                try db.execute(sql: "DELETE FROM pending_mutation WHERE id = ?", arguments: [rowId])
                self.pendingCount = max(0, self.pendingCount - db.changesCount)
                try self.applyUpdate(update, db, &cs)
            }
        }
        return Set(opened.map(\.0))
    }

    /// Forgets our own identity after a logout, so the next launch starts unpaired.
    public func forgetOwnIdentity() throws {
        try perform { db, _ in try Self.deleteOwnIdentity(db) }
    }

    private static func deleteOwnIdentity(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM meta WHERE key IN ('ownPn', 'ownLid')")
    }

    /// Creates an empty local chat for `jid` (new DM from the command bar) so it appears in the
    /// chat list; an existing chat is left alone. Returns the canonical JID.
    @discardableResult
    public func createLocalChat(_ jid: String, now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> String {
        let jid = canon(jid)
        try perform { db, _ in
            try self.ensureChat(db, jid)
            try db.execute(sql: "UPDATE chat SET lastActivityAt = ? WHERE jid = ? AND lastActivityAt IS NULL AND pinnedAt IS NULL",
                           arguments: [now, jid])
        }
        return jid
    }

    /// The UI opened `chatJid`: clears unread and marked-unread, returns what to mark read remotely.
    public func chatOpened(_ chatJid: String) throws -> OpenChatResult {
        let jid = canon(chatJid)
        return try perform { db, cs in
            guard let chat = try ChatRecord.fetchOne(db, key: jid) else {
                return OpenChatResult(unreadKeys: [], wasMarkedUnread: false)
            }
            var keys: [BridgeMessageKey] = []
            if chat.unreadCount > 0 {
                keys = try MessageRecord.fetchAll(db, sql: """
                    SELECT * FROM message WHERE chatJid = ? AND fromMe = 0 AND kind != 'system'
                    ORDER BY sortKey DESC LIMIT ?
                    """, arguments: [jid, min(chat.unreadCount, 1000)]).map(\.key)
            }
            if chat.unreadCount > 0 || chat.markedUnread {
                try db.execute(sql: "UPDATE chat SET unreadCount = 0, markedUnread = 0, stateAt = ? WHERE jid = ?",
                               arguments: [Self.now, jid])
            }
            cs.chatRead(jid)
            return OpenChatResult(unreadKeys: keys, wasMarkedUnread: chat.markedUnread)
        }
    }

    /// Inserts an optimistic outgoing message (status `pending`) and returns it.
    public func insertOutgoing(
        chatJid: String, text: String?, kind: MessageKind = .text,
        quoted: BridgeQuoted? = nil, media: BridgeOutgoingMedia? = nil, ownJid: String? = nil
    ) throws -> MessageItem {
        let jid = canon(chatJid)
        let localId = "local-" + UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970)
        return try perform { db, cs in
            try self.ensureChat(db, jid)
            self.ingestSeq += 1
            var rec = MessageRecord(
                localId: nil, chatJid: jid, id: localId, senderJid: ownJid ?? "", participant: nil, fromMe: true,
                timestamp: now, sortKey: SortKey.make(timestamp: now, seq: self.ingestSeq), kind: kind, text: text,
                quotedId: quoted?.id, quotedSenderJid: quoted?.senderJid, quotedKind: quoted?.kind, quotedSnippet: quoted?.snippet,
                status: .pending, editedAt: nil, revoked: false, isForwarded: false, typeName: nil, pushName: nil, extra: nil
            )
            try rec.insert(db)
            if let media {
                try MediaRecord(
                    chatJid: jid, messageId: localId, directPath: "", mediaKey: Data(), fileSha256: Data(), fileEncSha256: Data(),
                    fileLength: (try? FileManager.default.attributesOfItem(atPath: media.filePath)[.size] as? Int64) ?? 0,
                    mediaType: media.kind.mediaType, mimetype: media.mimetype, fileName: media.fileName,
                    width: media.width.map(Int.init), height: media.height.map(Int.init), durationSecs: media.durationSecs.map(Int.init),
                    jpegThumbnail: media.jpegThumbnail, waveform: nil, pageCount: media.pageCount.map(Int.init),
                    isAnimated: media.kind == .gif ? true : nil, sourcePath: media.filePath, downloadState: .downloaded
                ).insert(db)
            }
            try db.execute(sql: "UPDATE chat SET lastActivityAt = MAX(COALESCE(lastActivityAt, 0), ?) WHERE jid = ?", arguments: [now, jid])
            cs.add(jid, localId)
            return try MessageItemFetcher.items(db, chatJid: jid, ids: [localId])[0]
        }
    }

    /// Swaps the optimistic row for the server's id and marks it sent. `stored`: the sent file was
    /// copied into the media store; otherwise it is downloaded like any other media.
    public func completeSend(localId: String, chatJid: String, result: BridgeSendResult, stored: Bool = false) throws {
        let jid = canon(chatJid)
        try perform { db, cs in
            let newId = result.messageId
            let echoExists = try Bool.fetchOne(db, sql: "SELECT 1 FROM message WHERE chatJid = ? AND id = ?", arguments: [jid, newId]) ?? false
            if echoExists {
                try db.execute(sql: "DELETE FROM message WHERE chatJid = ? AND id = ?", arguments: [jid, localId])
                cs.delete(jid, localId)
                try self.applyMutation(db, jid, newId, .status(rank: MessageStatus.sent.rank), &cs)
                return
            }
            try db.execute(sql: """
                UPDATE message SET id = ?, timestamp = ?, status = MAX(status, ?),
                    participant = COALESCE(?, participant), participantInferred = CASE WHEN ? IS NULL THEN participantInferred ELSE 0 END
                WHERE chatJid = ? AND id = ?
                """, arguments: [newId, result.timestamp, MessageStatus.sent.rank, result.message.participant, result.message.participant, jid, localId])
            if let media = result.message.media {
                var rec = Self.mediaRecord(media, chatJid: jid, messageId: newId)
                rec.downloadState = stored ? .downloaded : .none
                try rec.upsert(db)
            }
            cs.replaced[jid, default: []].append((localId, newId))
            cs.dirty.insert(jid)
            try self.applyPending(db, jid, newId, &cs)
        }
    }

    public func failSend(localId: String, chatJid: String) throws {
        let jid = canon(chatJid)
        try perform { db, cs in
            try db.execute(sql: "UPDATE message SET status = ? WHERE chatJid = ? AND id = ? AND status = ?",
                           arguments: [MessageStatus.failed.rank, jid, localId, MessageStatus.pending.rank])
            cs.update(jid, localId)
        }
    }

    /// Puts a failed optimistic row back to `pending` before a retry.
    public func markPending(localId: String, chatJid: String) throws {
        let jid = canon(chatJid)
        try perform { db, cs in
            try db.execute(sql: "UPDATE message SET status = ? WHERE chatJid = ? AND id = ?",
                           arguments: [MessageStatus.pending.rank, jid, localId])
            cs.update(jid, localId)
        }
    }

    /// Optimistically applies a chat action made locally (pin, mute, archive, read/unread…).
    public func applyLocal(_ action: BridgeChatAction) throws {
        try perform { db, cs in try self.handleChatAction(action, db, &cs) }
    }

    public func applyGroups(_ groups: [BridgeGroup]) throws {
        try perform { db, _ in for g in groups { try self.handleGroup(g, db) } }
    }

    public func setAvatar(jid: String, present: Bool, checkedAt: Int64) throws {
        let jid = canon(jid)
        try perform { db, _ in
            try db.execute(sql: "UPDATE chat SET hasAvatar = ?, avatarCheckedAt = ? WHERE jid = ?", arguments: [present, checkedAt, jid])
        }
    }

    public func setBusiness(_ checks: [BridgeBusinessCheck], checkedAt: Int64) throws {
        let checks = checks.map { (jid: canon($0.jid), isBusiness: $0.isBusiness) }
        try perform { db, _ in
            for c in checks {
                try db.execute(sql: """
                    INSERT INTO contact (jid, isBusiness, businessCheckedAt) VALUES (?, ?, ?)
                    ON CONFLICT(jid) DO UPDATE SET isBusiness = excluded.isBusiness, businessCheckedAt = excluded.businessCheckedAt
                    """, arguments: [c.jid, c.isBusiness, checkedAt])
            }
        }
    }

    public func setMediaState(chatJid: String, messageId: String, state: MediaDownloadState) throws {
        let jid = canon(chatJid)
        try perform { db, cs in
            try db.execute(sql: "UPDATE media SET downloadState = ? WHERE chatJid = ? AND messageId = ?",
                           arguments: [state, jid, messageId])
            if db.changesCount > 0 { cs.update(jid, messageId) }
        }
    }

    /// Drops reaction/vote removal tombstones older than `cutoff`. Stale copies that could revive
    /// those come from history sync around the removal; delete-for-me tombstones are kept for good,
    /// since on-demand history can bring back a message of any age (and there are few of them).
    public func pruneTombstones(olderThan cutoff: Int64) throws {
        try perform { db, _ in
            try db.execute(sql: "DELETE FROM tombstone WHERE kind != 'message' AND timestamp < ?", arguments: [cutoff])
        }
    }

    /// Parked encrypted add-ons whose target is stored, oldest first (for the retry sweep).
    public func parkedEncryptedReady(limit: Int) throws -> [ParkedEnvelope] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.payload FROM pending_mutation p
                JOIN message m ON m.chatJid = p.chatJid AND m.id = p.messageId
                WHERE p.payload LIKE '{"encrypted"%' ORDER BY p.id LIMIT ?
                """, arguments: [limit]).compactMap { row in
                guard case .encrypted(let envelope)? = try? JSONDecoder().decode(MessageMutation.self, from: Data((row["payload"] as String).utf8))
                else { return nil }
                return ParkedEnvelope(rowId: row["id"], envelope: envelope)
            }
        }
    }

    /// Drops parked mutations whose target never arrived.
    public func prunePendingMutations(olderThan cutoff: Int64) throws {
        try perform { db, _ in
            try db.execute(sql: "DELETE FROM pending_mutation WHERE createdAt < ?", arguments: [cutoff])
            self.pendingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_mutation") ?? 0
        }
    }

    public func canonicalJid(_ jid: String) -> String { canon(jid) }

    // MARK: - Transaction plumbing

    /// One write transaction. In-memory bookkeeping mutated inside it (aliases, sequence numbers,
    /// pending count) is restored if the transaction rolls back.
    @discardableResult
    private func perform<T>(_ body: (Database, inout ChangeSet) throws -> T,
                            after: (inout T, ChangeSet) -> Void = { _, _ in }) throws -> T {
        var cs = ChangeSet()
        let saved = (aliases, ingestSeq, persistedSeq, pendingCount)
        var result: T
        do {
            result = try database.pool.write { db -> T in
                let r = try body(db, &cs)
                try finish(db, &cs)
                return r
            }
        } catch {
            (aliases, ingestSeq, persistedSeq, pendingCount) = saved
            throw error
        }
        publish(cs)
        for n in cs.notices { noticesContinuation.yield(n) }
        after(&result, cs)
        return result
    }

    private static var now: Int64 { Int64(Date().timeIntervalSince1970) }

    private func finish(_ db: Database, _ cs: inout ChangeSet) throws {
        for (jid, name) in cs.pushNames {
            try db.execute(sql: """
                INSERT INTO contact (jid, pushName) VALUES (?, ?)
                ON CONFLICT(jid) DO UPDATE SET pushName = excluded.pushName
                """, arguments: [jid, name])
        }
        for jid in cs.dirty { try refreshPreview(db, jid) }
        if !cs.alerts.isEmpty { try resolveAlerts(db, &cs) }
        try AppDatabase.backfillOwnGroupParticipants(db, groups: Array(Set(cs.added.keys).union(cs.participantEvidence)))
        if ingestSeq != persistedSeq {
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('ingestSeq', ?)", arguments: [String(ingestSeq)])
            persistedSeq = ingestSeq
        }
    }

    private func publish(_ cs: ChangeSet) {
        let observed = feed.observedChats
        guard !observed.isEmpty else { return }
        for jid in cs.touchedChats.intersection(observed) {
            if cs.reload.contains(jid) || (cs.added[jid]?.count ?? 0) > Self.maxAddsBeforeReload {
                feed.publish(.reload, chatJid: jid)
                continue
            }
            let deleted = cs.deleted[jid] ?? []
            let replaced = cs.replaced[jid] ?? []
            let added = cs.added[jid] ?? []
            let gone = Set(deleted)
            let addedSet = Set(added)
            let updated = (cs.updated[jid] ?? []).subtracting(addedSet).subtracting(gone)
            do {
                let (addItems, updateItems, replaceItems) = try database.pool.read { db in
                    (try MessageItemFetcher.items(db, chatJid: jid, ids: added.filter { !gone.contains($0) }),
                     try MessageItemFetcher.items(db, chatJid: jid, ids: Array(updated)),
                     try MessageItemFetcher.items(db, chatJid: jid, ids: replaced.map(\.new)))
                }
                if !deleted.isEmpty { feed.publish(.delete(ids: deleted), chatJid: jid) }
                let byId = Dictionary(replaceItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for r in replaced { if let item = byId[r.new] { feed.publish(.replace(oldId: r.old, item: item), chatJid: jid) } }
                if !addItems.isEmpty { feed.publish(.add(addItems), chatJid: jid) }
                if !updateItems.isEmpty { feed.publish(.update(updateItems), chatJid: jid) }
            } catch {
                WAKit.log.error("change feed read failed: \(error)")
                feed.publish(.reload, chatJid: jid)
            }
        }
    }

    // MARK: - Event handling

    private func handle(_ event: BridgeEvent, _ db: Database, _ cs: inout ChangeSet) throws {
        switch event {
        case .messages(let messages, let updates):
            for m in messages { try upsertMessage(m, live: true, db, &cs) }
            for u in updates { try applyUpdate(u, db, &cs) }
        case .receipt(let receipt):
            try handleReceipt(receipt, db, &cs)
        case .contacts(let contacts):
            for c in contacts { try upsertContact(c, db) }
        case .jidAliases(let aliases):
            for a in aliases { try mergeAlias(lid: a.lid, pn: a.pn, db, &cs) }
        case .chatAction(let action):
            try handleChatAction(action, db, &cs)
        case .group(let group):
            try handleGroup(group, db)
        case .pictureChanged(let jid):
            try db.execute(sql: "UPDATE chat SET hasAvatar = 0, avatarCheckedAt = NULL WHERE jid = ?", arguments: [canon(jid)])
        case .historyChunk(let chunk):
            for a in chunk.aliases { try mergeAlias(lid: a.lid, pn: a.pn, db, &cs) }
            for c in chunk.contacts { try upsertContact(c, db) }
            for c in chunk.chats { try upsertHistoryChat(c, db) }
            for m in chunk.messages { try upsertMessage(m, live: false, db, &cs) }
            for u in chunk.updates { try applyUpdate(u, db, &cs) }
        case .ownJid(let pn, let lid):
            if let pn { try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('ownPn', ?)", arguments: [pn]) }
            if let lid { try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('ownLid', ?)", arguments: [lid]) }
            if let pn, let lid { try mergeAlias(lid: lid, pn: pn, db, &cs) }
        case .pairing(.loggedOut):
            try Self.deleteOwnIdentity(db)
        case .connection, .pairing, .chatPresence, .presence, .offlineSyncCompleted:
            break
        }
    }

    private func canon(_ jid: String) -> String { aliases[jid] ?? jid }

    /// Renders a stub system message with the names known right now.
    private func systemText(_ db: Database, _ m: BridgeMessage, sender: String) throws -> String {
        try Self.renderSystem(db, typeName: m.typeName, raw: m.text, actor: sender, fromMe: m.fromMe, canon: canon)
    }

    static func renderSystem(_ db: Database, typeName: String?, raw: String?, actor: String, fromMe: Bool,
                             canon: (String) -> String) throws -> String {
        let own = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'ownPn'")
        var cache: [String: String] = [:]
        func name(_ jid: String) -> String {
            let j = canon(jid)
            if let hit = cache[j] { return hit }
            let resolved: String
            if j == own {
                resolved = "You"
            } else if let c = try? ContactRecord.fetchOne(db, key: j), let n = c.displayName.flatMap(ChatListQuery.unmasked) {
                resolved = n
            } else {
                resolved = JID.isPhoneNumber(j) ? (JID.phoneDisplay(j) ?? "Someone") : "Someone"
            }
            cache[j] = resolved
            return resolved
        }
        return SystemMessageText.render(typeName: typeName, raw: raw, actor: actor, actorIsMe: fromMe || canon(actor) == own, name: name)
    }

    private func ensureChat(_ db: Database, _ jid: String) throws {
        let kind = ChatKind(jid: jid)
        try db.execute(sql: "INSERT OR IGNORE INTO chat (jid, kind) VALUES (?, ?)", arguments: [jid, kind])
        if kind == .dm { try ensureContact(db, jid) }
    }

    /// Every person we know of has a contact row, named or not.
    private func ensureContact(_ db: Database, _ jid: String) throws {
        guard JID.isPhoneNumber(jid) || JID.isLid(jid) else { return }
        try db.execute(sql: "INSERT OR IGNORE INTO contact (jid) VALUES (?)", arguments: [jid])
    }

    // MARK: Messages

    private func upsertMessage(_ m: BridgeMessage, live: Bool, _ db: Database, _ cs: inout ChangeSet) throws {
        let chatJid = canon(m.chatJid)
        let sender = canon(m.senderJid)
        try ensureChat(db, chatJid)
        try ensureContact(db, sender)

        if !m.fromMe, let name = m.pushName, !name.isEmpty, !sender.isEmpty { cs.pushNames[sender] = name }

        // Deleted for me: a later (history or redelivered) copy must not bring it back.
        if hasMessageTombstones, try Self.tombstone(db, chatJid, m.id, .message) != nil {
            try dropPending(db, chatJid, m.id)
            return
        }

        let existing = try MessageRecord.fetchOne(db, sql: "SELECT * FROM message WHERE chatJid = ? AND id = ?",
                                                  arguments: [chatJid, m.id])
        let incomingStatus = m.status.map { MessageStatus(rank: $0.rank) }
        if var old = existing {
            if old.kind == .undecryptable, m.kind != .undecryptable {
                try upgradePlaceholder(&old, with: m, status: incomingStatus, live: live, db, &cs)
                return
            }
            // Re-delivery (history after live, or our own send echoed): merge forward-only fields.
            var sets: [String] = []
            var args: [any DatabaseValueConvertible] = []
            if let s = incomingStatus, s.rank > old.status.rank { sets.append("status = ?"); args.append(s.rank) }
            if m.revoked, !old.revoked {
                sets.append("revoked = 1, text = NULL")
                cs.removed(chatJid, m.id)
            }
            if let e = m.editedAt, e > (old.editedAt ?? 0), !m.revoked, !old.revoked {
                sets.append("text = ?, editedAt = ?"); args.append(m.text); args.append(e)
            }
            if !sets.isEmpty {
                try db.execute(sql: "UPDATE message SET \(sets.joined(separator: ", ")) WHERE chatJid = ? AND id = ?",
                               arguments: StatementArguments(args + [chatJid, m.id]))
                cs.update(chatJid, m.id)
            }
            if m.fromMe, let p = m.participant {
                // A reported participant (live echo) replaces a missing or guessed one; the
                // group's other guessed rows are re-derived from it at commit.
                try db.execute(sql: """
                    UPDATE message SET participant = ?, participantInferred = 0
                    WHERE chatJid = ? AND id = ? AND (participant IS NULL OR participantInferred = 1)
                    """, arguments: [p, chatJid, m.id])
                if db.changesCount > 0 { cs.dirty.insert(chatJid); cs.participantEvidence.insert(chatJid) }
            }
            if m.revoked || old.revoked {
                // Same as applyMutation(.revoke): a revoked message keeps no media.
                try db.execute(sql: "DELETE FROM media WHERE chatJid = ? AND messageId = ?", arguments: [chatJid, m.id])
            } else if let media = m.media {
                try db.execute(sql: "DELETE FROM media WHERE chatJid = ? AND messageId = ? AND directPath = ''", arguments: [chatJid, m.id])
                try Self.mediaRecord(media, chatJid: chatJid, messageId: m.id).insert(db, onConflict: .ignore)
            }
            for r in m.reactions {
                try applyMutation(db, chatJid, m.id, .reaction(senderJid: canon(r.senderJid), fromMe: r.fromMe, emoji: r.emoji, timestamp: r.timestamp), &cs)
            }
            return
        }

        ingestSeq += 1
        let extra = Self.extra(m)
        var rec = MessageRecord(
            localId: nil, chatJid: chatJid, id: m.id, senderJid: sender, participant: m.participant, fromMe: m.fromMe,
            timestamp: m.timestamp, sortKey: SortKey.make(timestamp: m.timestamp, seq: ingestSeq), kind: m.kind,
            text: m.revoked ? nil : (m.kind == .system ? try systemText(db, m, sender: sender) : m.text),
            quotedId: m.quoted?.id, quotedSenderJid: m.quoted?.senderJid.map(canon), quotedKind: m.quoted?.kind, quotedSnippet: m.quoted?.snippet,
            status: incomingStatus ?? (m.fromMe ? .sent : .delivered),
            editedAt: m.editedAt, revoked: m.revoked, isForwarded: m.isForwarded, typeName: m.typeName, pushName: m.pushName,
            extra: extra
        )
        try rec.insert(db)
        if rec.quotedId != nil, (rec.quotedSnippet ?? "").isEmpty {
            try db.execute(sql: AppDatabase.fillQuoteFromTargetSQL + " AND chatJid = ? AND id = ?", arguments: [chatJid, m.id])
        }
        if let media = m.media, !m.revoked {
            try Self.mediaRecord(media, chatJid: chatJid, messageId: m.id).insert(db, onConflict: .ignore)
        }
        for r in m.reactions where !r.emoji.isEmpty {
            let sender = canon(r.senderJid)
            if try Self.reactionSuppressed(db, chatJid, m.id, sender, fromMe: r.fromMe, timestamp: r.timestamp) { continue }
            try ReactionRecord(chatJid: chatJid, messageId: m.id, senderJid: sender, emoji: r.emoji,
                               fromMe: r.fromMe, timestamp: r.timestamp).upsert(db)
        }
        cs.add(chatJid, m.id)

        if live, !m.fromMe, m.kind != .system, !m.revoked {
            if focus.isReading(chatJid) {
                cs.readWhileFocused[chatJid, default: []].append(rec.key)
            } else {
                try db.execute(sql: "UPDATE chat SET unreadCount = unreadCount + 1 WHERE jid = ?", arguments: [chatJid])
                // A placeholder alerts once its real content arrives (`upgradePlaceholder`).
                if m.kind != .undecryptable { cs.alert(chatJid, m.id, m.timestamp) }
            }
        }
        try applyPending(db, chatJid, m.id, &cs)
    }

    private static func extra(_ m: BridgeMessage) -> MessageExtra? {
        let extra = MessageExtra(
            location: m.location.map { LocationInfo(latitude: $0.latitude, longitude: $0.longitude, name: $0.name, address: $0.address, isLive: $0.isLive) },
            contact: m.contact.map { ContactCardInfo(displayName: $0.displayName, vcard: $0.vcard) },
            poll: m.poll.map { PollInfo(question: $0.question, options: $0.options, selectableCount: Int($0.selectableCount)) }
        )
        return extra.isEmpty ? nil : extra
    }

    /// The real message replaced an undecryptable placeholder (live retry or history CIPHERTEXT
    /// stub). Takes its content; keeps the row's position, a higher status, and mutations already
    /// applied to the placeholder (revoke, a newer edit, reactions, votes). Unread was counted
    /// when the placeholder arrived.
    private func upgradePlaceholder(_ old: inout MessageRecord, with m: BridgeMessage, status: MessageStatus?, live: Bool,
                                    _ db: Database, _ cs: inout ChangeSet) throws {
        old.kind = m.kind
        old.extra = Self.extra(m)
        old.quotedId = m.quoted?.id
        old.quotedSenderJid = m.quoted?.senderJid.map(canon)
        old.quotedKind = m.quoted?.kind
        old.quotedSnippet = m.quoted?.snippet
        old.typeName = m.typeName
        old.pushName = m.pushName ?? old.pushName
        old.isForwarded = m.isForwarded
        if let status, status.rank > old.status.rank { old.status = status }
        old.revoked = old.revoked || m.revoked
        if old.revoked {
            old.text = nil
        } else if let applied = old.editedAt, (m.editedAt ?? 0) <= applied {
            // An edit already landed on the placeholder and is newer than this body.
        } else {
            old.text = m.text
            old.editedAt = m.editedAt ?? old.editedAt
        }
        try old.update(db)
        // Alerts only while the chat is still unread (not read since the placeholder arrived).
        if live, !old.fromMe, !old.revoked, old.kind != .system, !focus.isReading(old.chatJid),
           try Bool.fetchOne(db, sql: "SELECT unreadCount > 0 FROM chat WHERE jid = ?", arguments: [old.chatJid]) == true {
            cs.alert(old.chatJid, old.id, Self.now)  // the retry may land minutes after the send
        }
        try db.execute(sql: "DELETE FROM media WHERE chatJid = ? AND messageId = ?", arguments: [old.chatJid, old.id])
        if let media = m.media, !old.revoked {
            try Self.mediaRecord(media, chatJid: old.chatJid, messageId: old.id).insert(db)
        }
        for r in m.reactions {
            try applyMutation(db, old.chatJid, old.id, .reaction(senderJid: canon(r.senderJid), fromMe: r.fromMe, emoji: r.emoji, timestamp: r.timestamp), &cs)
        }
        cs.update(old.chatJid, old.id)
    }

    private func applyUpdate(_ u: BridgeMessageUpdate, _ db: Database, _ cs: inout ChangeSet) throws {
        switch u {
        case .edit(let target, let text, let editedAt):
            try applyOrPark(db, target, .edit(text: text, editedAt: editedAt), &cs)
        case .revoke(let target, _, let timestamp):
            try applyOrPark(db, target, .revoke(timestamp: timestamp), &cs)
        case .reaction(let target, let r):
            try applyOrPark(db, target, .reaction(senderJid: canon(r.senderJid), fromMe: r.fromMe, emoji: r.emoji, timestamp: r.timestamp), &cs)
        case .pollVote(let target, let voter, let selected, let timestamp):
            try applyOrPark(db, target, .pollVote(voterJid: canon(voter), selected: selected, timestamp: timestamp), &cs)
        case .encrypted(let target, let envelope):
            // Never applied inline: retried by `retryParked` once the target is inserted.
            try park(db, canon(target.chatJid), target.id, .encrypted(envelope: envelope))
        }
    }

    private func applyOrPark(_ db: Database, _ target: BridgeMessageKey, _ mutation: MessageMutation, _ cs: inout ChangeSet) throws {
        let chatJid = canon(target.chatJid)
        // Removals are remembered whether or not the target is here yet, so a stale copy of the
        // reaction or vote (history, a late redelivery) arriving later cannot resurrect it.
        switch mutation {
        case .reaction(let sender, _, let emoji, let ts) where emoji.isEmpty:
            try Self.recordTombstone(db, chatJid, target.id, .reaction, sender, ts)
        case .pollVote(let voter, let selected, let ts) where selected.isEmpty:
            try Self.recordTombstone(db, chatJid, target.id, .vote, voter, ts)
        default: break
        }
        if try !applyMutation(db, chatJid, target.id, mutation, &cs) {
            try park(db, chatJid, target.id, mutation)
        }
    }

    private func park(_ db: Database, _ chatJid: String, _ messageId: String, _ mutation: MessageMutation) throws {
        if hasMessageTombstones, try Self.tombstone(db, chatJid, messageId, .message) != nil { return }
        let payload = String(decoding: try JSONEncoder().encode(mutation), as: UTF8.self)
        try db.execute(sql: "INSERT INTO pending_mutation (chatJid, messageId, payload, createdAt) VALUES (?, ?, ?, ?)",
                       arguments: [chatJid, messageId, payload, Int64(Date().timeIntervalSince1970)])
        pendingCount += 1
    }

    private func applyPending(_ db: Database, _ chatJid: String, _ messageId: String, _ cs: inout ChangeSet) throws {
        guard pendingCount > 0 else { return }
        let rows = try Row.fetchAll(db, sql: "SELECT id, payload FROM pending_mutation WHERE chatJid = ? AND messageId = ? ORDER BY id",
                                    arguments: [chatJid, messageId])
        guard !rows.isEmpty else { return }
        var applied: [Int64] = []
        for row in rows {
            let payload: String = row["payload"]
            let rowId: Int64 = row["id"]
            switch try? JSONDecoder().decode(MessageMutation.self, from: Data(payload.utf8)) {
            case .encrypted(let envelope):
                // Stays parked until the caller has decrypted it after commit.
                cs.parked.append(ParkedEnvelope(rowId: rowId, envelope: envelope))
            case let mutation?:
                try applyMutation(db, chatJid, messageId, canonicalised(mutation), &cs)
                applied.append(rowId)
            case nil:
                applied.append(rowId)
            }
        }
        guard !applied.isEmpty else { return }
        try db.execute(sql: "DELETE FROM pending_mutation WHERE id IN (\(applied.map { _ in "?" }.joined(separator: ",")))",
                       arguments: StatementArguments(applied))
        pendingCount = max(0, pendingCount - applied.count)
    }

    private func dropPending(_ db: Database, _ chatJid: String, _ messageId: String) throws {
        guard pendingCount > 0 else { return }
        try db.execute(sql: "DELETE FROM pending_mutation WHERE chatJid = ? AND messageId = ?", arguments: [chatJid, messageId])
        pendingCount = max(0, pendingCount - db.changesCount)
    }

    /// Parked mutations keep the sender JID they arrived with; an alias learned since then applies.
    private func canonicalised(_ mutation: MessageMutation) -> MessageMutation {
        switch mutation {
        case .reaction(let sender, let fromMe, let emoji, let ts): .reaction(senderJid: canon(sender), fromMe: fromMe, emoji: emoji, timestamp: ts)
        case .pollVote(let voter, let selected, let ts): .pollVote(voterJid: canon(voter), selected: selected, timestamp: ts)
        case .edit, .revoke, .status, .encrypted: mutation
        }
    }

    // MARK: Tombstones

    enum TombstoneKind: String {
        /// Deleted for me; `senderJid` is empty.
        case message
        /// A sender removed their reaction / cleared their vote at `timestamp`.
        case reaction, vote
    }

    /// The tombstone's timestamp, if there is one.
    static func tombstone(_ db: Database, _ chatJid: String, _ id: String, _ kind: TombstoneKind, _ sender: String = "") throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT timestamp FROM tombstone WHERE chatJid = ? AND messageId = ? AND kind = ? AND senderJid = ?",
                           arguments: [chatJid, id, kind.rawValue, sender])
    }

    /// Clock skew allowed between our own removal (stamped by this Mac, or by another device) and
    /// our own later re-reaction (stamped by whichever device made it).
    static let ownReactionSkew: Int64 = 60

    /// A reaction is dropped only when a removal by the same sender is known to be newer. A
    /// timestamp of 0 is unknown (some history copies carry none) and is never suppressed.
    static func reactionSuppressed(_ db: Database, _ chatJid: String, _ id: String, _ sender: String,
                                   fromMe: Bool, timestamp ts: Int64) throws -> Bool {
        guard ts > 0, let removedAt = try tombstone(db, chatJid, id, .reaction, sender) else { return false }
        return removedAt > ts + (fromMe ? ownReactionSkew : 0)
    }

    static func recordTombstone(_ db: Database, _ chatJid: String, _ id: String, _ kind: TombstoneKind, _ sender: String, _ ts: Int64) throws {
        try db.execute(sql: """
            INSERT INTO tombstone (chatJid, messageId, kind, senderJid, timestamp) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(chatJid, messageId, kind, senderJid) DO UPDATE SET timestamp = MAX(timestamp, excluded.timestamp)
            """, arguments: [chatJid, id, kind.rawValue, sender, ts])
    }

    /// Votes on polls the bridge has not seen this session arrive as lowercase hex SHA-256 of the
    /// option name; resolve them against the stored poll so stored votes are always names.
    private func resolvePollOptions(_ selected: [String], _ db: Database, _ chatJid: String, _ id: String) throws -> [String] {
        func isHash(_ s: String) -> Bool { s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard selected.contains(where: isHash),
              let options = try MessageRecord.fetchOne(db, key: ["chatJid": chatJid, "id": id])?.extra?.poll?.options
        else { return selected }
        let byHash = Dictionary(options.map { (Self.sha256Hex($0), $0) }, uniquingKeysWith: { a, _ in a })
        return selected.map { byHash[$0] ?? $0 }
    }

    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns false when the target message does not exist (caller parks the mutation).
    @discardableResult
    private func applyMutation(_ db: Database, _ chatJid: String, _ id: String, _ mutation: MessageMutation, _ cs: inout ChangeSet) throws -> Bool {
        guard try Bool.fetchOne(db, sql: "SELECT 1 FROM message WHERE chatJid = ? AND id = ?", arguments: [chatJid, id]) == true else {
            return false
        }
        let key: StatementArguments = [chatJid, id]
        switch mutation {
        case .edit(let text, let editedAt):
            try db.execute(sql: """
                UPDATE message SET text = ?, editedAt = ?
                WHERE chatJid = ? AND id = ? AND revoked = 0 AND (editedAt IS NULL OR editedAt <= ?)
                """, arguments: [text, editedAt] + key + [editedAt])
        case .revoke:
            try db.execute(sql: "UPDATE message SET revoked = 1, text = NULL WHERE chatJid = ? AND id = ?", arguments: key)
            try db.execute(sql: "DELETE FROM media WHERE chatJid = ? AND messageId = ?", arguments: key)
            cs.removed(chatJid, id)
        case .reaction(let sender, let fromMe, let emoji, let ts):
            if !emoji.isEmpty, try Self.reactionSuppressed(db, chatJid, id, sender, fromMe: fromMe, timestamp: ts) {
                return true
            }
            if emoji.isEmpty {
                try db.execute(sql: "DELETE FROM reaction WHERE chatJid = ? AND messageId = ? AND senderJid = ? AND timestamp <= ?",
                               arguments: key + [sender, ts])
            } else {
                try db.execute(sql: """
                    INSERT INTO reaction (chatJid, messageId, senderJid, emoji, fromMe, timestamp) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(chatJid, messageId, senderJid) DO UPDATE SET
                        emoji = excluded.emoji, fromMe = excluded.fromMe, timestamp = excluded.timestamp
                    WHERE excluded.timestamp >= reaction.timestamp
                    """, arguments: key + [sender, emoji, fromMe, ts])
            }
        case .pollVote(let voter, let selected, let ts):
            if !selected.isEmpty, ts > 0, let clearedAt = try Self.tombstone(db, chatJid, id, .vote, voter), clearedAt > ts {
                return true
            }
            if selected.isEmpty {
                try db.execute(sql: "DELETE FROM poll_vote WHERE chatJid = ? AND messageId = ? AND voterJid = ? AND timestamp <= ?",
                               arguments: key + [voter, ts])
            } else {
                let selected = try resolvePollOptions(selected, db, chatJid, id)
                let json = String(decoding: try JSONEncoder().encode(selected), as: UTF8.self)
                try db.execute(sql: """
                    INSERT INTO poll_vote (chatJid, messageId, voterJid, selected, timestamp) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(chatJid, messageId, voterJid) DO UPDATE SET
                        selected = excluded.selected, timestamp = excluded.timestamp
                    WHERE excluded.timestamp >= poll_vote.timestamp
                    """, arguments: key + [voter, json, ts])
            }
        case .status(let rank):
            try db.execute(sql: "UPDATE message SET status = ? WHERE chatJid = ? AND id = ? AND status < ?",
                           arguments: [rank] + key + [rank])
            guard db.changesCount > 0 else { return true }
        case .encrypted:
            return false
        }
        cs.update(chatJid, id)
        return true
    }

    // MARK: Receipts

    private func handleReceipt(_ r: BridgeReceipt, _ db: Database, _ cs: inout ChangeSet) throws {
        let chatJid = canon(r.chatJid)
        let status: MessageStatus
        switch r.kind {
        case .sent: status = .sent
        case .delivered: status = .delivered
        case .read, .played: status = .read
        case .readSelf, .playedSelf:
            try db.execute(sql: "UPDATE chat SET unreadCount = 0, stateAt = ? WHERE jid = ?", arguments: [Self.now, chatJid])
            cs.chatRead(chatJid)
            return
        case .retry, .other:
            return
        }
        for id in r.messageIds {
            if try !applyMutation(db, chatJid, id, .status(rank: status.rank), &cs) {
                try park(db, chatJid, id, .status(rank: status.rank))
            }
        }
    }

    // MARK: Chats, contacts, groups

    private func upsertContact(_ c: BridgeContact, _ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO contact (jid, fullName, firstName, pushName, phone) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(jid) DO UPDATE SET
                fullName = COALESCE(excluded.fullName, fullName),
                firstName = COALESCE(excluded.firstName, firstName),
                pushName = COALESCE(excluded.pushName, pushName),
                phone = COALESCE(excluded.phone, phone)
            """, arguments: [canon(c.jid), c.fullName, c.firstName, c.pushName, c.phone])
    }

    private func upsertHistoryChat(_ c: BridgeChat, _ db: Database) throws {
        let jid = canon(c.jid)
        // A snapshot from the phone. Its unread/marked-unread/pin/mute/archive state applies to new
        // rows and to rows that only exist because live traffic created them first (`stateAt IS
        // NULL`). Once a chat action or read has set that state here (`stateAt`), a later, possibly
        // stale snapshot never re-applies it.
        try db.execute(sql: """
            INSERT INTO chat (jid, kind, name, lastActivityAt, unreadCount, markedUnread, pinnedAt, mutedUntil, archived, readOnly)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(jid) DO UPDATE SET
                name = COALESCE(excluded.name, name),
                lastActivityAt = CASE
                    WHEN excluded.lastActivityAt IS NULL THEN lastActivityAt
                    WHEN lastActivityAt IS NULL THEN excluded.lastActivityAt
                    ELSE MAX(lastActivityAt, excluded.lastActivityAt) END,
                unreadCount = CASE WHEN stateAt IS NULL THEN MAX(unreadCount, excluded.unreadCount) ELSE unreadCount END,
                markedUnread = CASE WHEN stateAt IS NULL THEN excluded.markedUnread ELSE markedUnread END,
                pinnedAt = CASE WHEN stateAt IS NULL THEN excluded.pinnedAt ELSE pinnedAt END,
                mutedUntil = CASE WHEN stateAt IS NULL THEN excluded.mutedUntil ELSE mutedUntil END,
                archived = CASE WHEN stateAt IS NULL THEN excluded.archived ELSE archived END,
                readOnly = excluded.readOnly
            """, arguments: [jid, c.kind, c.name, c.lastActivityAt, Int(c.unreadCount), c.markedUnread,
                             c.pinnedAt, c.mutedUntil, c.archived, c.readOnly])
        if c.kind == .dm { try ensureContact(db, jid) }
    }

    private func handleChatAction(_ action: BridgeChatAction, _ db: Database, _ cs: inout ChangeSet) throws {
        switch action {
        case .pin(let jid, let pinnedAt):
            let jid = canon(jid)
            try ensureChat(db, jid)
            try db.execute(sql: "UPDATE chat SET pinnedAt = ?, stateAt = ? WHERE jid = ?", arguments: [pinnedAt, Self.now, jid])
        case .mute(let jid, let until):
            let jid = canon(jid)
            try ensureChat(db, jid)
            try db.execute(sql: "UPDATE chat SET mutedUntil = ?, stateAt = ? WHERE jid = ?", arguments: [until, Self.now, jid])
        case .archive(let jid, let archived):
            let jid = canon(jid)
            try ensureChat(db, jid)
            try db.execute(sql: "UPDATE chat SET archived = ?, stateAt = ? WHERE jid = ?", arguments: [archived, Self.now, jid])
        case .markRead(let jid, let read):
            let jid = canon(jid)
            if read {
                try db.execute(sql: "UPDATE chat SET unreadCount = 0, markedUnread = 0, stateAt = ? WHERE jid = ?", arguments: [Self.now, jid])
                cs.chatRead(jid)
            } else {
                try db.execute(sql: "UPDATE chat SET markedUnread = 1, stateAt = ? WHERE jid = ?", arguments: [Self.now, jid])
            }
        case .delete(let jid, let cutoff):
            let jid = canon(jid)
            // Messages newer than the synced range arrived after the delete: keep them and the chat.
            let newer = try cutoff.map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE chatJid = ? AND timestamp > ?", arguments: [jid, $0]) ?? 0
            } ?? 0
            if let cutoff, newer > 0 {
                try clearMessages(jid, upTo: cutoff, db, &cs)
            } else {
                try db.execute(sql: "DELETE FROM chat WHERE jid = ?", arguments: [jid])
                try db.execute(sql: "DELETE FROM pending_mutation WHERE chatJid = ?", arguments: [jid])
                cs.reload.insert(jid)
                cs.chatRead(jid)
            }
        case .clear(let jid, let cutoff):
            try clearMessages(canon(jid), upTo: cutoff, db, &cs)
        case .deleteMessageForMe(let target):
            let jid = canon(target.chatJid)
            // Remembered even when the message is not here yet, so it never appears later.
            try Self.recordTombstone(db, jid, target.id, .message, "", 0)
            hasMessageTombstones = true
            try db.execute(sql: "DELETE FROM message WHERE chatJid = ? AND id = ?", arguments: [jid, target.id])
            if db.changesCount > 0 { cs.delete(jid, target.id) }
            cs.removed(jid, target.id)
            try dropPending(db, jid, target.id)
        }
    }

    /// Deletes messages at or before `cutoff` (all when nil); unread never exceeds what is left.
    private func clearMessages(_ jid: String, upTo cutoff: Int64?, _ db: Database, _ cs: inout ChangeSet) throws {
        if let cutoff {
            // Newer messages survive, and so do their notifications: withdraw only what goes.
            let gone = try String.fetchAll(db, sql: """
                SELECT id FROM message WHERE chatJid = ? AND fromMe = 0 AND timestamp <= ?
                ORDER BY sortKey DESC LIMIT 500
                """, arguments: [jid, cutoff])
            for id in gone { cs.removed(jid, id) }
        } else {
            cs.chatRead(jid)
        }
        try db.execute(sql: "DELETE FROM message WHERE chatJid = ? AND (? IS NULL OR timestamp <= ?)", arguments: [jid, cutoff, cutoff])
        try db.execute(sql: """
            UPDATE chat SET unreadCount = MIN(unreadCount,
                (SELECT COUNT(*) FROM message WHERE chatJid = ? AND fromMe = 0 AND kind != 'system'))
            WHERE jid = ?
            """, arguments: [jid, jid])
        cs.reload.insert(jid)
        cs.dirty.insert(jid)
    }

    private func handleGroup(_ g: BridgeGroup, _ db: Database) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO chat (jid, kind) VALUES (?, 'group')", arguments: [g.jid])
        // A zero count is unknown: keep the stored one, except that a membership change
        // (`membershipChanged`) makes it stale, so it is cleared for `GroupService` to re-fetch.
        let count: Int? = g.participantCount > 0 ? Int(g.participantCount) : nil
        let stale = g.membershipChanged && count == nil
        try db.execute(sql: """
            UPDATE chat SET name = COALESCE(?, name),
                participantCount = CASE WHEN ? IS NOT NULL THEN ? WHEN ? THEN NULL ELSE participantCount END
            WHERE jid = ?
            """, arguments: [g.subject.nonEmpty, count, count, stale, g.jid])
        guard !g.participants.isEmpty else { return }
        try db.execute(sql: "DELETE FROM group_participant WHERE groupJid = ?", arguments: [g.jid])
        for p in g.participants {
            let jid = canon(p.jid)
            try GroupParticipantRecord(groupJid: g.jid, jid: jid, isAdmin: p.isAdmin, isSuperAdmin: p.isSuperAdmin)
                .insert(db, onConflict: .replace)
            try ensureContact(db, jid)
        }
    }

    // MARK: Notifications

    /// Turns `cs.alerts` into incoming notices, oldest first. Only chats the list shows alert (not
    /// status updates or newsletters), and not when muted or archived; revoked messages and anything
    /// older than `maxAlertAge` stay silent.
    private func resolveAlerts(_ db: Database, _ cs: inout ChangeSet) throws {
        let cutoff = Self.now - Self.maxAlertAge
        let own = try ChatListQuery.ownJid(db)
        var incoming: [IncomingNotice] = []
        for (jid, alert) in cs.alerts {
            let id = alert.id
            guard alert.timestamp >= cutoff,
                  let chat = try ChatRecord.fetchOne(db, key: jid), [.dm, .group, .broadcast].contains(chat.kind),
                  !chat.isMuted(), !chat.archived,
                  let m = try MessageRecord.fetchOne(db, sql: "SELECT * FROM message WHERE chatJid = ? AND id = ?", arguments: [jid, id]),
                  !m.revoked else { continue }
            let contact = chat.kind == .dm ? try ContactRecord.fetchOne(db, key: jid) : nil
            var sender: String?
            if chat.kind != .dm {
                sender = try ContactRecord.fetchOne(db, key: m.senderJid)?.displayName.flatMap(ChatListQuery.unmasked)
                    ?? m.pushName.nonEmpty ?? JID.phoneDisplay(m.senderJid)
            }
            incoming.append(IncomingNotice(
                chatJid: jid, messageId: id, chatTitle: ChatListQuery.title(chat, contact, ownJid: own),
                senderName: sender, kind: m.kind, text: m.text, timestamp: m.timestamp,
                avatarURL: chat.avatarURL))
        }
        cs.notices += incoming.sorted { $0.timestamp < $1.timestamp }.map(NoticeEvent.incoming)
    }

    private func refreshPreview(_ db: Database, _ jid: String) throws {
        if let row = try Row.fetchOne(db, sql: """
            SELECT id, kind, text, fromMe, senderJid, status, revoked, timestamp FROM message
            WHERE chatJid = ? ORDER BY sortKey DESC LIMIT 1
            """, arguments: [jid]) {
            let text: String? = row["text"]
            try db.execute(sql: """
                UPDATE chat SET lastMessageId = ?, lastMessageKind = ?, lastMessageText = ?, lastMessageFromMe = ?,
                    lastMessageSenderJid = ?, lastMessageStatus = ?, lastMessageRevoked = ?,
                    lastActivityAt = MAX(COALESCE(lastActivityAt, 0), ?)
                WHERE jid = ?
                """, arguments: [row["id"], row["kind"], text.map { String($0.prefix(200)) }, row["fromMe"],
                                 row["senderJid"], row["status"], row["revoked"], row["timestamp"], jid])
        } else {
            try db.execute(sql: """
                UPDATE chat SET lastMessageId = NULL, lastMessageKind = NULL, lastMessageText = NULL, lastMessageFromMe = NULL,
                    lastMessageSenderJid = NULL, lastMessageStatus = NULL, lastMessageRevoked = NULL
                WHERE jid = ?
                """, arguments: [jid])
        }
    }

    // MARK: Alias merging

    /// Records `lid → pn` and folds everything stored under the LID into the phone-number JID.
    private func mergeAlias(lid: String, pn: String, _ db: Database, _ cs: inout ChangeSet) throws {
        guard !lid.isEmpty, !pn.isEmpty, lid != pn else { return }
        guard aliases[lid] != pn else { return }
        aliases[lid] = pn
        if let a = cs.alerts.removeValue(forKey: lid) { cs.alert(pn, a.id, a.timestamp) }
        try JidAliasRecord(lid: lid, pn: pn).upsert(db)

        // Contacts
        if let lc = try ContactRecord.fetchOne(db, key: lid) {
            try db.execute(sql: """
                INSERT INTO contact (jid, fullName, firstName, pushName, phone, isBusiness, businessCheckedAt) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(jid) DO UPDATE SET
                    fullName = COALESCE(fullName, excluded.fullName),
                    firstName = COALESCE(firstName, excluded.firstName),
                    pushName = COALESCE(pushName, excluded.pushName),
                    phone = COALESCE(phone, excluded.phone),
                    isBusiness = isBusiness OR excluded.isBusiness,
                    businessCheckedAt = COALESCE(businessCheckedAt, excluded.businessCheckedAt)
                """, arguments: [pn, lc.fullName, lc.firstName, lc.pushName, lc.phone, lc.isBusiness, lc.businessCheckedAt])
            try db.execute(sql: "DELETE FROM contact WHERE jid = ?", arguments: [lid])
        }

        // Chat and its messages
        if let lidChat = try ChatRecord.fetchOne(db, key: lid) {
            if let pnChat = try ChatRecord.fetchOne(db, key: pn) {
                // Messages present under both JIDs are counted in both unread windows; count once.
                let overlap = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM
                        (SELECT id FROM message WHERE chatJid = ? AND fromMe = 0 AND kind != 'system' ORDER BY sortKey DESC LIMIT ?) l
                    JOIN
                        (SELECT id FROM message WHERE chatJid = ? AND fromMe = 0 AND kind != 'system' ORDER BY sortKey DESC LIMIT ?) p
                    USING (id)
                    """, arguments: [lid, lidChat.unreadCount, pn, pnChat.unreadCount]) ?? 0
                let dupIds = try String.fetchAll(db, sql: """
                    SELECT l.id FROM message l JOIN message p ON p.chatJid = ? AND p.id = l.id WHERE l.chatJid = ?
                    """, arguments: [pn, lid])
                for id in dupIds { try reconcileDuplicate(id, from: lid, into: pn, db) }
                let lidStateAt = try Int64.fetchOne(db, sql: "SELECT stateAt FROM chat WHERE jid = ?", arguments: [lid])
                try db.execute(sql: """
                    UPDATE chat SET
                        name = COALESCE(name, ?),
                        stateAt = CASE WHEN ? IS NULL THEN stateAt ELSE MAX(COALESCE(stateAt, 0), ?) END,
                        unreadCount = unreadCount + ?,
                        markedUnread = markedUnread OR ?,
                        pinnedAt = COALESCE(pinnedAt, ?),
                        mutedUntil = COALESCE(mutedUntil, ?),
                        archived = ?,
                        avatarCheckedAt = CASE WHEN hasAvatar THEN avatarCheckedAt ELSE NULL END,
                        lastActivityAt = MAX(COALESCE(lastActivityAt, 0), COALESCE(?, 0))
                    WHERE jid = ?
                    """, arguments: [lidChat.name, lidStateAt, lidStateAt, max(0, lidChat.unreadCount - overlap), lidChat.markedUnread, lidChat.pinnedAt,
                                     lidChat.mutedUntil, pnChat.archived && lidChat.archived,
                                     lidChat.lastActivityAt, pn])
                // Duplicates (same id under both JIDs), now reconciled into the PN copy, stay behind
                // and are deleted with the LID chat.
                try db.execute(sql: "UPDATE OR IGNORE message SET chatJid = ? WHERE chatJid = ?", arguments: [pn, lid])
                try db.execute(sql: "UPDATE OR IGNORE chat_tag SET chatJid = ? WHERE chatJid = ?", arguments: [pn, lid])
                try db.execute(sql: "DELETE FROM chat WHERE jid = ?", arguments: [lid])
            } else {
                // ON UPDATE CASCADE carries messages, media, reactions, votes and tags along.
                try db.execute(sql: "UPDATE chat SET jid = ? WHERE jid = ?", arguments: [pn, lid])
                // The cached picture is named after the old JID; fetch it again under the new one.
                try db.execute(sql: "UPDATE chat SET hasAvatar = 0, avatarCheckedAt = NULL WHERE jid = ?", arguments: [pn])
            }
            cs.reload.formUnion([lid, pn])
            cs.dirty.insert(pn)
        }

        try db.execute(sql: "UPDATE message SET senderJid = ? WHERE senderJid = ?", arguments: [pn, lid])
        try db.execute(sql: "UPDATE chat SET lastMessageSenderJid = ? WHERE lastMessageSenderJid = ?", arguments: [pn, lid])
        try db.execute(sql: "UPDATE OR REPLACE reaction SET senderJid = ? WHERE senderJid = ?", arguments: [pn, lid])
        try db.execute(sql: "UPDATE OR REPLACE poll_vote SET voterJid = ? WHERE voterJid = ?", arguments: [pn, lid])
        try db.execute(sql: "UPDATE OR REPLACE group_participant SET jid = ? WHERE jid = ?", arguments: [pn, lid])
        // Folded into the PN spelling keeping the newest removal time, then the LID rows go.
        try db.execute(sql: """
            INSERT INTO tombstone (chatJid, messageId, kind, senderJid, timestamp)
            SELECT CASE WHEN chatJid = ?1 THEN ?2 ELSE chatJid END, messageId, kind,
                   CASE WHEN senderJid = ?1 THEN ?2 ELSE senderJid END, timestamp
            FROM tombstone WHERE chatJid = ?1 OR senderJid = ?1
            ON CONFLICT(chatJid, messageId, kind, senderJid) DO UPDATE SET timestamp = MAX(timestamp, excluded.timestamp)
            """, arguments: [lid, pn])
        try db.execute(sql: "DELETE FROM tombstone WHERE chatJid = ?1 OR senderJid = ?1", arguments: [lid])

        if pendingCount > 0 {
            try db.execute(sql: "UPDATE pending_mutation SET chatJid = ? WHERE chatJid = ?", arguments: [pn, lid])
            // Targets that moved into the PN chat may now satisfy parked mutations.
            let targets = try String.fetchAll(db, sql: """
                SELECT DISTINCT p.messageId FROM pending_mutation p
                JOIN message m ON m.chatJid = p.chatJid AND m.id = p.messageId
                WHERE p.chatJid = ?
                """, arguments: [pn])
            for id in targets { try applyPending(db, pn, id, &cs) }
        }
    }

    /// Folds the LID copy of a message that also exists under the PN chat into the PN copy:
    /// real content over a placeholder, revoked if either is, the newest edit, the higher status,
    /// and the union of reactions and votes (newest per sender).
    private func reconcileDuplicate(_ id: String, from lid: String, into pn: String, _ db: Database) throws {
        guard let l = try MessageRecord.fetchOne(db, key: ["chatJid": lid, "id": id]),
              var p = try MessageRecord.fetchOne(db, key: ["chatJid": pn, "id": id]) else { return }
        let original = p
        var takeMedia = false
        if p.kind == .undecryptable, l.kind != .undecryptable {
            p.kind = l.kind; p.text = l.text; p.extra = l.extra; p.editedAt = l.editedAt
            p.quotedId = l.quotedId; p.quotedSenderJid = l.quotedSenderJid; p.quotedKind = l.quotedKind; p.quotedSnippet = l.quotedSnippet
            p.typeName = l.typeName; p.isForwarded = l.isForwarded; p.pushName = p.pushName ?? l.pushName
            takeMedia = true
        }
        if l.status.rank > p.status.rank { p.status = l.status }
        if l.revoked || p.revoked {
            p.revoked = true
            p.text = nil
        } else if let e = l.editedAt, e > (p.editedAt ?? 0) {
            p.text = l.text
            p.editedAt = e
        }
        if p != original { try p.update(db) }
        let pnKey: StatementArguments = [pn, id]
        if p.revoked {
            try db.execute(sql: "DELETE FROM media WHERE chatJid = ? AND messageId = ?", arguments: pnKey)
        } else if var media = try MediaRecord.fetchOne(db, key: ["chatJid": lid, "messageId": id]) {
            if takeMedia { try db.execute(sql: "DELETE FROM media WHERE chatJid = ? AND messageId = ?", arguments: pnKey) }
            media.chatJid = pn
            try media.insert(db, onConflict: .ignore)
        }
        try db.execute(sql: """
            INSERT INTO reaction (chatJid, messageId, senderJid, emoji, fromMe, timestamp)
            SELECT ?, messageId, senderJid, emoji, fromMe, timestamp FROM reaction WHERE chatJid = ? AND messageId = ?
            ON CONFLICT(chatJid, messageId, senderJid) DO UPDATE SET
                emoji = excluded.emoji, fromMe = excluded.fromMe, timestamp = excluded.timestamp
            WHERE excluded.timestamp > reaction.timestamp
            """, arguments: [pn, lid, id])
        try db.execute(sql: """
            INSERT INTO poll_vote (chatJid, messageId, voterJid, selected, timestamp)
            SELECT ?, messageId, voterJid, selected, timestamp FROM poll_vote WHERE chatJid = ? AND messageId = ?
            ON CONFLICT(chatJid, messageId, voterJid) DO UPDATE SET
                selected = excluded.selected, timestamp = excluded.timestamp
            WHERE excluded.timestamp > poll_vote.timestamp
            """, arguments: [pn, lid, id])
    }

    // MARK: Mapping

    static func mediaRecord(_ m: BridgeMedia, chatJid: String, messageId: String) -> MediaRecord {
        MediaRecord(
            chatJid: chatJid, messageId: messageId, directPath: m.directPath, mediaKey: m.mediaKey,
            fileSha256: m.fileSha256, fileEncSha256: m.fileEncSha256, fileLength: Int64(clamping: m.fileLength),
            mediaType: m.mediaType, mimetype: m.mimetype, fileName: m.fileName,
            width: m.width.map(Int.init), height: m.height.map(Int.init), durationSecs: m.durationSecs.map(Int.init),
            jpegThumbnail: m.jpegThumbnail, waveform: m.waveform, pageCount: m.pageCount.map(Int.init),
            isAnimated: m.isAnimated, sourcePath: nil, downloadState: .none
        )
    }
}

extension BridgeMessageUpdate {
    var isEncrypted: Bool { if case .encrypted = self { true } else { false } }
}

extension SendMediaKind {
    var mediaType: BridgeMediaType {
        switch self {
        case .image: .image
        case .video, .gif: .video
        case .document: .document
        }
    }
}
