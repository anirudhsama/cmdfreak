import CryptoKit
import Dispatch
import Foundation
import GRDB
import os

/// A mutation of a message that may arrive before the message itself; parked in `pending_mutation`.
enum MessageMutation: Codable, Hashable, Sendable {
    case edit(text: String?, mentions: [String]?, editedAt: Int64)
    case revoke(timestamp: Int64)
    case reaction(senderJid: String, fromMe: Bool, emoji: String, timestamp: Int64)
    case pollVote(voterJid: String, selected: [String], timestamp: Int64)
    case status(rank: Int)
    /// A group member's delivered/read receipt for our message.
    case receipt(readerJid: String, rank: Int)
    /// The server rejected our message: pending becomes failed.
    case rejected
    /// An encrypted edit or poll vote whose parent secret the bridge lacked; retried through
    /// `WaBridge.decryptParked` once the target is stored.
    case encrypted(envelope: Data)
    /// Another of our devices read this incoming message before it reached us: it arrives read.
    case readElsewhere
}

/// An outbound change in `outbox`, queued in the transaction of the local change it mirrors and
/// kept until the server confirmed it. The row's `chatJid` and `messageId` (the target message;
/// empty for chat actions) name what it applies to; `previous` is what a give-up restores.
enum OutboxChange: Codable, Hashable, Sendable {
    case receipt
    case reaction(fromMe: Bool, participant: String?, emoji: String, timestamp: Int64, previous: OwnReaction?)
    /// `mentions`: the JIDs the edited text's "@<number>"s stand for, and `previousMentions` the list a
    /// give-up restores. Rows queued before these existed decode `mentions` as nil and keep the list.
    case edit(text: String, editedAt: Int64, previousText: String?, previousEditedAt: Int64?,
              mentions: [String]? = nil, previousMentions: [String]? = nil)
    case revoke(fromMe: Bool, participant: String?, previousText: String?, previousMedia: MediaRecord?)
    case pin(pinnedAt: Int64?, previous: Int64?)
    case mute(until: Int64?, previous: Int64?)
    case archive(archived: Bool, previous: Bool)
    case markRead(read: Bool, previousMarkedUnread: Bool)

    struct OwnReaction: Codable, Hashable, Sendable {
        var senderJid: String
        var emoji: String
        var timestamp: Int64
    }

    /// `.receipt` as stored; the queue writes these in bulk.
    static let receiptPayload = #"{"receipt":{}}"#

    /// The `outbox.kind` column: one row per kind and target.
    var kind: String {
        switch self {
        case .receipt: "receipt"
        case .reaction: "reaction"
        case .edit: "edit"
        case .revoke: "revoke"
        case .pin: "pin"
        case .mute: "mute"
        case .archive: "archive"
        case .markRead: "markRead"
        }
    }

    /// For a chat action, whether it turns the state on (pinned, muted, archived, read).
    var chatActionValue: Bool? {
        switch self {
        case .pin(let pinnedAt, _): pinnedAt != nil
        case .mute(let until, _): until != nil
        case .archive(let archived, _): archived
        case .markRead(let read, _): read
        case .receipt, .reaction, .edit, .revoke: nil
        }
    }

    /// This change, replacing `sent` while it was in flight, after the server confirmed `sent`: a
    /// give-up now restores `sent`.
    func restoring(confirmed sent: OutboxChange, ownSender: String) -> OutboxChange {
        switch (self, sent) {
        case let (.reaction(fromMe, participant, emoji, ts, _), .reaction(_, _, sentEmoji, sentTs, _)):
            .reaction(fromMe: fromMe, participant: participant, emoji: emoji, timestamp: ts,
                      previous: sentEmoji.isEmpty ? nil : OwnReaction(senderJid: ownSender, emoji: sentEmoji, timestamp: sentTs))
        case let (.edit(text, editedAt, _, _, mentions, previousMentions), .edit(sentText, sentAt, _, _, sentMentions, _)):
            // A row queued before mention lists left the message's list as it was.
            .edit(text: text, editedAt: editedAt, previousText: sentText, previousEditedAt: sentAt,
                  mentions: mentions, previousMentions: sentMentions ?? previousMentions)
        case let (.pin(pinnedAt, _), .pin(sent, _)): .pin(pinnedAt: pinnedAt, previous: sent)
        case let (.mute(until, _), .mute(sent, _)): .mute(until: until, previous: sent)
        case let (.archive(archived, _), .archive(sent, _)): .archive(archived: archived, previous: sent)
        case let (.markRead(read, _), .markRead(sent, _)): .markRead(read: read, previousMarkedUnread: !sent)
        default: self
        }
    }

    /// Replacing a queued change of the same kind: what the server last confirmed is still the
    /// older row's `previous`.
    func keepingPrevious(of older: OutboxChange) -> OutboxChange {
        switch (self, older) {
        case let (.reaction(fromMe, participant, emoji, ts, _), .reaction(_, _, _, _, previous)):
            .reaction(fromMe: fromMe, participant: participant, emoji: emoji, timestamp: ts, previous: previous)
        case let (.edit(text, editedAt, _, _, mentions, ownPrevious), .edit(_, _, previousText, previousEditedAt, olderMentions, previousMentions)):
            .edit(text: text, editedAt: editedAt, previousText: previousText, previousEditedAt: previousEditedAt,
                  mentions: mentions, previousMentions: olderMentions == nil ? ownPrevious : previousMentions)
        case let (.pin(pinnedAt, _), .pin(_, previous)): .pin(pinnedAt: pinnedAt, previous: previous)
        case let (.mute(until, _), .mute(_, previous)): .mute(until: until, previous: previous)
        case let (.archive(archived, _), .archive(_, previous)): .archive(archived: archived, previous: previous)
        case let (.markRead(read, _), .markRead(_, previous)): .markRead(read: read, previousMarkedUnread: previous)
        default: self
        }
    }
}

/// A queued change other than a read receipt, as `Outbox` sends it.
struct OutboxEntry: Sendable {
    let id: Int64
    let chatJid: String
    let messageId: String
    let change: OutboxChange
}

/// What `Outbox` sends in one pass: read receipts per chat (with their row ids), then the rest in
/// queue order.
struct OutboxDue: Sendable {
    var receipts: [(chatJid: String, rowIds: [Int64], keys: [BridgeMessageKey])] = []
    var changes: [OutboxEntry] = []
}

/// A parked encrypted add-on whose target has been stored; `retryParked` decrypts and applies it.
public struct ParkedEnvelope: Sendable, Hashable {
    let rowId: Int64
    let envelope: Data
}

/// What one applied batch leaves for the caller to do after commit.
struct IngestResult {
    /// Incoming messages read in the focused chat (per chat), their receipts queued in `outbox`.
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
    var verifiedNames: [String: String] = [:]
    /// Incoming live messages that landed in the focused chat: not counted unread, and their read
    /// receipts queued in `outbox` for the caller to flush after commit.
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
    /// Unread incoming messages now owed read receipts (queued in `outbox`).
    public var unreadKeys: [BridgeMessageKey]
    /// The chat was marked unread; clearing that is queued in `outbox` too.
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
    /// Chat actions `Outbox` is sending, by kind and chat, with the state each sets. After the
    /// patch lands, the library's re-sync replays it to us as if from another device.
    private var echoes: [String: (on: Bool, at: ContinuousClock.Instant)] = [:]

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
        try Self.failInterruptedSends(database)
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

    /// Our own edit of `key`, queued for the server. `mentions` are the JIDs the edit names; those of the
    /// message's own mentions still in the new text are kept, so they resolve as before.
    public func localEdit(_ key: BridgeMessageKey, text: String, mentions: [String] = [], editedAt: Int64) throws {
        try perform { db, cs in
            let jid = self.canon(key.chatJid)
            let old = try Row.fetchOne(db, sql: """
                SELECT text, editedAt, json_extract(extra, '$.mentions') AS mentions FROM message WHERE chatJid = ? AND id = ?
                """, arguments: [jid, key.id])
            let previous = try (old?["mentions"] as String?).map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
            let users = Set(Mentions.ranges(in: text).map(\.user))
            var kept = mentions
            for m in previous ?? [] where users.contains(JID.user(m)) && !kept.contains(m) { kept.append(m) }
            try self.applyOrPark(db, key, .edit(text: text, mentions: Mentions.stored(kept, text: text), editedAt: editedAt), &cs)
            try self.enqueue(db, jid, key.id, .edit(text: text, editedAt: editedAt, previousText: old?["text"],
                                                   previousEditedAt: old?["editedAt"], mentions: kept,
                                                   previousMentions: previous))
        }
    }

    /// Our own reaction to `key` ("" removes it), queued for the server.
    public func localReaction(_ key: BridgeMessageKey, emoji: String, senderJid: String, timestamp: Int64) throws {
        try perform { db, cs in
            let jid = self.canon(key.chatJid)
            let previous = try Self.ownReaction(db, jid, key.id)
            let reaction = BridgeReaction(senderJid: senderJid, fromMe: true, emoji: emoji, timestamp: timestamp)
            try self.applyUpdate(.reaction(target: key, reaction: reaction), db, &cs)
            try self.enqueue(db, jid, key.id, .reaction(fromMe: key.fromMe, participant: key.participant, emoji: emoji,
                                                       timestamp: timestamp, previous: previous))
        }
    }

    /// Our own delete-for-everyone of `key`, queued for the server.
    public func localRevoke(_ key: BridgeMessageKey, timestamp: Int64) throws {
        try perform { db, cs in
            let jid = self.canon(key.chatJid)
            // The revoke drops our edits and reactions still queued for it; undo them first, so a
            // revoke that never lands restores what the server has.
            for row in try Row.fetchAll(db, sql: """
                SELECT kind, payload FROM outbox WHERE chatJid = ? AND messageId = ? AND kind IN ('edit', 'reaction')
                """, arguments: [jid, key.id]) {
                if let change = try? JSONDecoder().decode(OutboxChange.self, from: Data((row["payload"] as String).utf8)) {
                    try self.revert(change, jid, key.id, db, &cs)
                }
            }
            let text = try String.fetchOne(db, sql: "SELECT text FROM message WHERE chatJid = ? AND id = ?", arguments: [jid, key.id])
            let media = try MediaRecord.fetchOne(db, key: ["chatJid": jid, "messageId": key.id])
            try self.applyOrPark(db, key, .revoke(timestamp: timestamp), &cs)
            try self.enqueue(db, jid, key.id, .revoke(fromMe: key.fromMe, participant: key.participant, previousText: text, previousMedia: media))
        }
    }

    /// The UI opened `chatJid`: clears unread and marked-unread, returns what to mark read remotely.
    public func chatOpened(_ chatJid: String) throws -> OpenChatResult {
        let jid = canon(chatJid)
        return try perform { db, cs in
            guard let chat = try ChatRecord.fetchOne(db, key: jid) else {
                return OpenChatResult(unreadKeys: [], wasMarkedUnread: false)
            }
            let keys = try Self.unreadKeys(db, chat)
            if chat.unreadCount > 0 || chat.markedUnread {
                try db.execute(sql: "UPDATE message SET unread = 0 WHERE chatJid = ? AND unread", arguments: [jid])
                try db.execute(sql: """
                    UPDATE chat SET unreadCount = 0, unreadUnattributed = 0, markedUnread = 0, stateAt = ? WHERE jid = ?
                    """, arguments: [Self.now, jid])
            }
            try Self.queueReads(db, keys)
            if chat.markedUnread { try self.enqueue(db, jid, "", .markRead(read: true, previousMarkedUnread: true)) }
            cs.chatRead(jid)
            return OpenChatResult(unreadKeys: keys, wasMarkedUnread: chat.markedUnread)
        }
    }

    /// Inserts an optimistic outgoing message (status `pending`) and returns it.
    public func insertOutgoing(
        chatJid: String, text: String?, mentions: [String] = [], kind: MessageKind = .text,
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
                status: .pending, editedAt: nil, revoked: false, isForwarded: false, typeName: nil, pushName: nil,
                extra: Self.outgoingExtra(text: text, mentions: mentions, quoted: quoted)
            )
            try rec.insert(db)
            try db.execute(sql: "UPDATE message SET sentHere = 1 WHERE chatJid = ? AND id = ?", arguments: [jid, localId])
            try self.stampRecipients(db, jid, localId)
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

    /// Swaps the optimistic row for the server's id. It stays pending until the server acks it
    /// (`handleServerAck`). `stored`: the sent file was copied into the media store; otherwise it is
    /// downloaded like any other media.
    public func completeSend(localId: String, chatJid: String, result: BridgeSendResult, stored: Bool = false) throws {
        let jid = canon(chatJid)
        try perform { db, cs in
            let newId = result.messageId
            // An ack that beat us here may be parked under another spelling of the chat (or none).
            try db.execute(sql: """
                UPDATE pending_mutation SET chatJid = ?
                WHERE messageId = ? AND chatJid != ? AND (payload LIKE '{"status":%' OR payload LIKE '{"rejected":%')
                """, arguments: [jid, newId, jid])
            let echoExists = try Bool.fetchOne(db, sql: "SELECT 1 FROM message WHERE chatJid = ? AND id = ?", arguments: [jid, newId]) ?? false
            if echoExists {
                try db.execute(sql: "DELETE FROM message WHERE chatJid = ? AND id = ?", arguments: [jid, localId])
                cs.delete(jid, localId)
                try self.applyMutation(db, jid, newId, .status(rank: MessageStatus.sent.rank), &cs)
                return
            }
            try db.execute(sql: """
                UPDATE message SET id = ?, timestamp = ?,
                    participant = COALESCE(?, participant), participantInferred = CASE WHEN ? IS NULL THEN participantInferred ELSE 0 END
                WHERE chatJid = ? AND id = ?
                """, arguments: [newId, result.timestamp, result.message.participant, result.message.participant, jid, localId])
            if let media = result.message.media {
                var rec = Self.mediaRecord(media, chatJid: jid, messageId: newId)
                rec.downloadState = stored ? .downloaded : .none
                // Not in the media store: the staged file is what a resend uploads.
                if !stored {
                    rec.sourcePath = try String.fetchOne(db, sql: "SELECT sourcePath FROM media WHERE chatJid = ? AND messageId = ?",
                                                         arguments: [jid, newId])
                }
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
            // Sent from here now, whatever sent it first, so it's ours to resend until acked.
            try db.execute(sql: "UPDATE message SET status = ?, sentHere = 1 WHERE chatJid = ? AND id = ?",
                           arguments: [MessageStatus.pending.rank, jid, localId])
            cs.update(jid, localId)
        }
    }

    /// Optimistically applies a chat action made locally (pin, mute, archive, read/unread) and
    /// queues it for the server.
    public func applyLocal(_ action: BridgeChatAction) throws {
        try perform { db, cs in
            let queued = try self.outboxChange(for: action, db)
            // Marking a chat read sends its read receipts, as opening it does.
            if case .markRead(let jid, true, _, _) = action, let chat = try ChatRecord.fetchOne(db, key: self.canon(jid)) {
                try Self.queueReads(db, Self.unreadKeys(db, chat))
            }
            try self.handleChatAction(action, local: true, db, &cs)
            if let (jid, change) = queued { try self.enqueue(db, jid, "", change) }
        }
    }

    /// The outbox row for a local chat action, with the state it replaces.
    private func outboxChange(for action: BridgeChatAction, _ db: Database) throws -> (String, OutboxChange)? {
        func chat(_ jid: String) throws -> (String, ChatRecord?) {
            let jid = canon(jid)
            return (jid, try ChatRecord.fetchOne(db, key: jid))
        }
        switch action {
        case .pin(let jid, let pinnedAt):
            let (jid, c) = try chat(jid)
            return (jid, .pin(pinnedAt: pinnedAt, previous: c?.pinnedAt))
        case .mute(let jid, let until):
            let (jid, c) = try chat(jid)
            return (jid, .mute(until: until, previous: c?.mutedUntil))
        case .archive(let jid, let archived):
            let (jid, c) = try chat(jid)
            return (jid, .archive(archived: archived, previous: c?.archived ?? false))
        case .markRead(let jid, let read, _, _):
            let (jid, c) = try chat(jid)
            return (jid, .markRead(read: read, previousMarkedUnread: c?.markedUnread ?? false))
        case .delete, .clear, .deleteMessageForMe:
            return nil
        }
    }

    public func applyGroups(_ groups: [BridgeGroup]) throws {
        try perform { db, cs in for g in groups { try self.handleGroup(g, db, &cs) } }
    }

    /// Records the check on the chat and, for a person, on their contact row (group members often
    /// have no chat).
    public func setAvatar(jid: String, present: Bool, checkedAt: Int64) throws {
        let jid = canon(jid)
        try perform { db, _ in
            try db.execute(sql: "UPDATE chat SET hasAvatar = ?, avatarCheckedAt = ? WHERE jid = ?", arguments: [present, checkedAt, jid])
            guard JID.isPhoneNumber(jid) || JID.isLid(jid) else { return }
            try db.execute(sql: """
                INSERT INTO contact (jid, hasAvatar, avatarCheckedAt) VALUES (?, ?, ?)
                ON CONFLICT(jid) DO UPDATE SET hasAvatar = excluded.hasAvatar, avatarCheckedAt = excluded.avatarCheckedAt
                """, arguments: [jid, present, checkedAt])
        }
    }

    public func setBusiness(_ checks: [BridgeBusinessCheck], checkedAt: Int64) throws {
        let checks = checks.map { (jid: canon($0.jid), isBusiness: $0.isBusiness, verifiedName: $0.verifiedName) }
        try perform { db, _ in
            for c in checks {
                try db.execute(sql: """
                    INSERT INTO contact (jid, isBusiness, businessCheckedAt, verifiedName) VALUES (?, ?, ?, ?)
                    ON CONFLICT(jid) DO UPDATE SET isBusiness = excluded.isBusiness, businessCheckedAt = excluded.businessCheckedAt,
                        verifiedName = COALESCE(excluded.verifiedName, verifiedName)
                    """, arguments: [c.jid, c.isBusiness, checkedAt, c.verifiedName])
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

    /// Drops reaction/vote removal and add-on tombstones older than `cutoff`. Stale copies that could
    /// revive those come from history sync around the removal; delete-for-me tombstones are kept for good,
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

    /// Drops parked mutations whose target never arrived. Read markers are the only record of a
    /// read on another device, and their message can still come after a long offline spell, so
    /// they have their own, longer cutoff.
    public func prunePendingMutations(olderThan cutoff: Int64, readMarkersOlderThan markerCutoff: Int64) throws {
        try perform { db, _ in
            try db.execute(sql: """
                DELETE FROM pending_mutation
                WHERE createdAt < CASE WHEN payload LIKE '{"readElsewhere"%' THEN ? ELSE ? END
                """, arguments: [markerCutoff, cutoff])
            self.pendingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_mutation") ?? 0
        }
    }

    public func canonicalJid(_ jid: String) -> String { canon(jid) }

    // MARK: Outbox

    /// What reading `chat` here sends receipts for: its unread messages, and for a snapshot's
    /// unattributed count the newest others.
    private static func unreadKeys(_ db: Database, _ chat: ChatRecord) throws -> [BridgeMessageKey] {
        guard chat.unreadCount > 0 else { return [] }
        return try MessageRecord.fetchAll(db, sql: """
            SELECT * FROM message WHERE chatJid = ? AND fromMe = 0 AND kind != 'system'
              AND (unread OR localId IN (
                  SELECT localId FROM message WHERE chatJid = ? AND fromMe = 0 AND kind != 'system' AND NOT unread
                  ORDER BY sortKey DESC LIMIT (SELECT unreadUnattributed FROM chat WHERE jid = ?)))
            ORDER BY sortKey DESC LIMIT 1000
            """, arguments: [chat.jid, chat.jid, chat.jid]).map(\.key)
    }

    /// Owes read receipts for `keys` until the server acks them. Runs in the transaction that reads them.
    private static func queueReads(_ db: Database, _ keys: [BridgeMessageKey]) throws {
        for k in keys {
            try db.execute(sql: "INSERT OR IGNORE INTO outbox (kind, chatJid, messageId, payload, queuedAt) VALUES ('receipt', ?, ?, ?, ?)",
                           arguments: [k.chatJid, k.id, OutboxChange.receiptPayload, now])
        }
    }

    /// Queues `change`, replacing a queued change of the same kind for the same target. The
    /// replacement gets a new row id, so a pass still sending the old one doesn't remove it. A
    /// revoke already queued stays as it is.
    private func enqueue(_ db: Database, _ chatJid: String, _ messageId: String, _ change: OutboxChange) throws {
        var change = change
        if let old = try Row.fetchOne(db, sql: "SELECT id, payload FROM outbox WHERE kind = ? AND chatJid = ? AND messageId = ?",
                                      arguments: [change.kind, chatJid, messageId]) {
            if case .revoke = change { return }
            if let older = try? JSONDecoder().decode(OutboxChange.self, from: Data((old["payload"] as String).utf8)) {
                change = change.keepingPrevious(of: older)
            }
            try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [old["id"] as Int64])
        }
        try db.execute(sql: "INSERT INTO outbox (kind, chatJid, messageId, payload, queuedAt) VALUES (?, ?, ?, ?, ?)",
                       arguments: [change.kind, chatJid, messageId, String(decoding: try JSONEncoder().encode(change), as: UTF8.self), Self.now])
    }

    /// One `Outbox` pass: receipts per chat in message order, then the other changes in queue
    /// order. What no longer applies goes first, unsent: receipts for messages gone, and changes
    /// newer state has overtaken.
    func outboxDue() throws -> OutboxDue {
        try perform { db, _ in
            try db.execute(sql: """
                DELETE FROM outbox WHERE kind = 'receipt'
                  AND NOT EXISTS (SELECT 1 FROM message WHERE message.chatJid = outbox.chatJid AND message.id = outbox.messageId)
                """)
            var due = OutboxDue()
            let receipts = try Row.fetchAll(db, sql: """
                SELECT o.id, m.chatJid, m.id AS messageId, m.fromMe, m.participant FROM outbox o
                JOIN message m ON m.chatJid = o.chatJid AND m.id = o.messageId
                WHERE o.kind = 'receipt' ORDER BY m.sortKey
                """)
            var byChat: [String: Int] = [:]
            for row in receipts {
                let chat: String = row["chatJid"]
                let key = BridgeMessageKey(chatJid: chat, id: row["messageId"], fromMe: row["fromMe"], participant: row["participant"])
                if let i = byChat[chat] {
                    due.receipts[i].rowIds.append(row["id"])
                    due.receipts[i].keys.append(key)
                } else {
                    byChat[chat] = due.receipts.count
                    due.receipts.append((chat, [row["id"]], [key]))
                }
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, chatJid, messageId, payload FROM outbox WHERE kind != 'receipt' ORDER BY id") {
                let entry = OutboxEntry(id: row["id"], chatJid: row["chatJid"], messageId: row["messageId"],
                                        change: (try? JSONDecoder().decode(OutboxChange.self, from: Data((row["payload"] as String).utf8))) ?? .receipt)
                if case .receipt = entry.change {
                    try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [entry.id])
                } else if try Self.superseded(entry, db) {
                    WAKit.log.info("outbox: \(entry.change.kind, privacy: .public) superseded, not sent")
                    try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [entry.id])
                } else {
                    due.changes.append(entry)
                }
            }
            return due
        }
    }

    /// Newer state overtook the queued change (a later change by us here or on another device):
    /// sending it would overwrite that. Receipts and revokes are idempotent and never are.
    private static func superseded(_ e: OutboxEntry, _ db: Database) throws -> Bool {
        let chat = { try ChatRecord.fetchOne(db, key: e.chatJid) }
        switch e.change {
        case .receipt, .revoke:
            return false
        case .reaction(_, _, let emoji, _, _):
            guard try Bool.fetchOne(db, sql: "SELECT 1 FROM message WHERE chatJid = ? AND id = ?", arguments: [e.chatJid, e.messageId]) == true
            else { return true }
            return try (ownReaction(db, e.chatJid, e.messageId)?.emoji ?? "") != emoji
        case .edit(let text, let editedAt, _, _, _, _):
            return try Bool.fetchOne(db, sql: """
                SELECT 1 FROM message WHERE chatJid = ? AND id = ? AND revoked = 0 AND text IS ? AND editedAt IS ?
                """, arguments: [e.chatJid, e.messageId, text, editedAt]) != true
        case .pin(let pinnedAt, _):
            guard let c = try chat() else { return true }
            return c.isPinned != (pinnedAt != nil)
        case .mute(let until, _):
            guard let c = try chat() else { return true }
            return c.mutedUntil != until
        case .archive(let archived, _):
            guard let c = try chat() else { return true }
            return c.archived != archived
        case .markRead(let read, _):
            guard let c = try chat() else { return true }
            return c.markedUnread == read
        }
    }

    /// Right before `Outbox` sends `e`: whether it still applies. One replaced or overtaken since
    /// the pass began is not sent. A chat action is noted so its echo is recognised.
    func claimOutbox(_ e: OutboxEntry) throws -> Bool {
        try perform { db, _ in
            guard try Bool.fetchOne(db, sql: "SELECT 1 FROM outbox WHERE id = ?", arguments: [e.id]) == true else { return false }
            if try Self.superseded(e, db) {
                WAKit.log.info("outbox: \(e.change.kind, privacy: .public) superseded, not sent")
                try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [e.id])
                return false
            }
            if let on = e.change.chatActionValue { self.echoes[e.change.kind + " " + e.chatJid] = (on, .now) }
            return true
        }
    }

    /// The server confirmed rows `ids`; `entry` is the change they carried (nil for receipts). A
    /// newer change that replaced it meanwhile now falls back to it on a give-up.
    func outboxSent(_ ids: [Int64], entry: OutboxEntry? = nil) throws {
        guard !ids.isEmpty else { return }
        try perform { db, _ in
            try db.execute(sql: "DELETE FROM outbox WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))", arguments: StatementArguments(ids))
            guard let entry, let newer = try Row.fetchOne(db, sql: """
                SELECT id, payload FROM outbox WHERE kind = ? AND chatJid = ? AND messageId = ?
                """, arguments: [entry.change.kind, entry.chatJid, entry.messageId]),
                  let change = try? JSONDecoder().decode(OutboxChange.self, from: Data((newer["payload"] as String).utf8))
            else { return }
            let ownSender = try Self.ownReaction(db, entry.chatJid, entry.messageId)?.senderJid
                ?? String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'ownPn'") ?? ""
            let updated = change.restoring(confirmed: entry.change, ownSender: ownSender)
            try db.execute(sql: "UPDATE outbox SET payload = ? WHERE id = ?",
                           arguments: [String(decoding: try JSONEncoder().encode(updated), as: UTF8.self), newer["id"] as Int64])
        }
    }

    /// Sending rows `ids` failed. A `counted` failure (the connection was up throughout) adds an
    /// attempt; rows at `maxAttempts` give up. Returns whether any did.
    @discardableResult
    func outboxFailed(_ ids: [Int64], entry: OutboxEntry? = nil, error: String, counted: Bool, maxAttempts: Int) throws -> Bool {
        guard !ids.isEmpty else { return false }
        // Not applied, so no echo comes.
        if let entry { echoes[entry.change.kind + " " + entry.chatJid] = nil }
        let list = ids.map { _ in "?" }.joined(separator: ",")
        return try perform { db, cs in
            try db.execute(sql: "UPDATE outbox SET lastError = ?, attempts = attempts + ? WHERE id IN (\(list))",
                           arguments: [error, counted ? 1 : 0] + StatementArguments(ids))
            let spent = try Row.fetchAll(db, sql: "SELECT * FROM outbox WHERE attempts >= ? AND id IN (\(list))",
                                         arguments: [maxAttempts] + StatementArguments(ids))
            for row in spent { try self.giveUp(row, db, &cs) }
            return !spent.isEmpty
        }
    }

    /// Gives up on rows queued before `cutoff`: they could not be sent for so long that they no
    /// longer matter, or the user's change should not land this late.
    public func pruneOutbox(olderThan cutoff: Int64) throws {
        try perform { db, cs in
            for row in try Row.fetchAll(db, sql: "SELECT * FROM outbox WHERE queuedAt < ?", arguments: [cutoff]) {
                try self.giveUp(row, db, &cs)
            }
        }
    }

    /// Drops an outbox row the server never took. A receipt just goes; a change of ours is undone
    /// locally, so this Mac shows what the server and our other devices have.
    private func giveUp(_ row: Row, _ db: Database, _ cs: inout ChangeSet) throws {
        let kind: String = row["kind"], chatJid: String = row["chatJid"], messageId: String = row["messageId"]
        try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [row["id"] as Int64])
        guard kind != "receipt",
              let change = try? JSONDecoder().decode(OutboxChange.self, from: Data((row["payload"] as String).utf8)) else { return }
        WAKit.log.error("""
            outbox: gave up on \(kind, privacy: .public) after \(row["attempts"] as Int) attempts \
            (\(row["lastError"] as String? ?? "", privacy: .public)); undone here
            """)
        try revert(change, chatJid, messageId, db, &cs)
    }

    /// Undoes our local `change`, back to its `previous`, unless newer state replaced it meanwhile.
    private func revert(_ change: OutboxChange, _ chatJid: String, _ messageId: String, _ db: Database, _ cs: inout ChangeSet) throws {
        let key: StatementArguments = [chatJid, messageId]
        switch change {
        case .receipt:
            break
        case .reaction(_, _, let emoji, let timestamp, let previous):
            guard try (Self.ownReaction(db, chatJid, messageId)?.emoji ?? "") == emoji else { return }
            try db.execute(sql: "DELETE FROM reaction WHERE chatJid = ? AND messageId = ? AND fromMe = 1", arguments: key)
            if emoji.isEmpty {
                try db.execute(sql: "DELETE FROM tombstone WHERE chatJid = ? AND messageId = ? AND kind = 'reaction' AND timestamp = ?",
                               arguments: key + [timestamp])
            }
            if let p = previous {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO reaction (chatJid, messageId, senderJid, emoji, fromMe, timestamp) VALUES (?, ?, ?, ?, 1, ?)
                    """, arguments: key + [p.senderJid, p.emoji, p.timestamp])
            }
            cs.update(chatJid, messageId)
        case .edit(let text, let editedAt, let previousText, let previousEditedAt, let mentions, let previousMentions):
            let restore = mentions == nil ? "" : ", " + Self.setMentionsSQL
            let previousJSON = try Self.mentionsJSON(previousMentions)
            try db.execute(sql: """
                UPDATE message SET text = ?, editedAt = ?\(restore) WHERE chatJid = ? AND id = ? AND revoked = 0 AND text IS ? AND editedAt IS ?
                """, arguments: [previousText, previousEditedAt] + (mentions == nil ? [] : [previousJSON, previousJSON]) + key + [text, editedAt])
            if db.changesCount > 0 { cs.update(chatJid, messageId) }
        case .revoke(_, _, let previousText, let previousMedia):
            try db.execute(sql: "UPDATE message SET revoked = 0, text = ? WHERE chatJid = ? AND id = ? AND revoked = 1",
                           arguments: [previousText] + key)
            guard db.changesCount > 0 else { return }
            if var media = previousMedia {
                // Stored under the chat's JID at the time, which an alias merge may have changed.
                media.chatJid = chatJid
                media.messageId = messageId
                try media.insert(db, onConflict: .ignore)
            }
            cs.update(chatJid, messageId)
        case .pin(let pinnedAt, let previous):
            try db.execute(sql: "UPDATE chat SET pinnedAt = ? WHERE jid = ? AND (pinnedAt IS NULL) = ?",
                           arguments: [previous, chatJid, pinnedAt == nil])
        case .mute(let until, let previous):
            try db.execute(sql: "UPDATE chat SET mutedUntil = ? WHERE jid = ? AND mutedUntil IS ?", arguments: [previous, chatJid, until])
        case .archive(let archived, let previous):
            try db.execute(sql: "UPDATE chat SET archived = ? WHERE jid = ? AND archived = ?", arguments: [previous, chatJid, archived])
        case .markRead(let read, let previous):
            try db.execute(sql: "UPDATE chat SET markedUnread = ? WHERE jid = ? AND markedUnread = ?", arguments: [previous, chatJid, !read])
        }
    }

    /// Our newest reaction to the message, from this Mac or another of our devices.
    private static func ownReaction(_ db: Database, _ chatJid: String, _ id: String) throws -> OutboxChange.OwnReaction? {
        try Row.fetchOne(db, sql: """
            SELECT senderJid, emoji, timestamp FROM reaction WHERE chatJid = ? AND messageId = ? AND fromMe = 1
            ORDER BY timestamp DESC LIMIT 1
            """, arguments: [chatJid, id]).map { OutboxChange.OwnReaction(senderJid: $0["senderJid"], emoji: $0["emoji"], timestamp: $0["timestamp"]) }
    }

    public func canonicalJids(_ jids: Set<String>) -> [String: String] {
        Dictionary(uniqueKeysWithValues: jids.map { ($0, canon($0)) })
    }

    /// Of `jids` (possibly LIDs since merged), those whose chat has no unread messages or no longer
    /// exists: notifications delivered for them are stale.
    public func readChats(among jids: Set<String>) throws -> Set<String> {
        let unread = try database.pool.read { db in
            try String.fetchSet(db, sql: "SELECT jid FROM chat WHERE unreadCount > 0")
        }
        return jids.filter { !unread.contains(canon($0)) }
    }

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
        // Only business accounts carry a verified name. `BusinessService` still checks them, and
        // clears the flag for one that switched back to a personal account.
        for (jid, name) in cs.verifiedNames {
            try db.execute(sql: """
                INSERT INTO contact (jid, verifiedName, isBusiness) VALUES (?, ?, 1)
                ON CONFLICT(jid) DO UPDATE SET verifiedName = excluded.verifiedName, isBusiness = 1
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
        case .serverAck(let ack):
            try handleServerAck(ack, db, &cs)
        case .contacts(let contacts):
            for c in contacts { try upsertContact(c, db) }
        case .jidAliases(let aliases):
            for a in aliases { try mergeAlias(lid: a.lid, pn: a.pn, db, &cs) }
        case .chatAction(let action):
            try handleChatAction(action, db, &cs)
        case .group(let group):
            try handleGroup(group, db, &cs)
        case .pictureChanged(let jid):
            try db.execute(sql: "UPDATE chat SET hasAvatar = 0, avatarCheckedAt = NULL WHERE jid = ?", arguments: [canon(jid)])
            try db.execute(sql: "UPDATE contact SET hasAvatar = 0, avatarCheckedAt = NULL WHERE jid = ?", arguments: [canon(jid)])
        case .historyChunk(let chunk):
            for a in chunk.aliases { try mergeAlias(lid: a.lid, pn: a.pn, db, &cs) }
            for c in chunk.contacts { try upsertContact(c, db) }
            for c in chunk.chats { try upsertHistoryChat(c, db) }
            for m in chunk.messages { try upsertMessage(m, live: false, db, &cs) }
            for u in chunk.updates { try applyUpdate(u, db, &cs) }
            for c in chunk.chats { try attributeSnapshotUnread(c, db) }
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
        if !m.fromMe, let name = m.verifiedName, !name.isEmpty, !sender.isEmpty { cs.verifiedNames[sender] = name }

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
                let mentions = try Self.mentionsJSON(Mentions.stored(m.mentions, text: m.text))
                sets.append("text = ?, editedAt = ?, \(Self.setMentionsSQL)")
                args += [m.text, e, mentions, mentions]
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
        if live, m.fromMe { try stampRecipients(db, chatJid, m.id) }
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
                try Self.queueReads(db, [rec.key])
            } else if try readElsewhere(db, chatJid, m) {
                // Read on another device before it reached us.
            } else {
                // One more flag, one more in the count: no recount on this hot path.
                try db.execute(sql: "UPDATE message SET unread = 1 WHERE chatJid = ? AND id = ?", arguments: [chatJid, m.id])
                try db.execute(sql: "UPDATE chat SET unreadCount = unreadCount + 1 WHERE jid = ?", arguments: [chatJid])
                // A placeholder alerts once its real content arrives (`upgradePlaceholder`).
                if m.kind != .undecryptable { cs.alert(chatJid, m.id, m.timestamp) }
            }
        } else if live, m.fromMe, ![.system, .undecryptable].contains(m.kind), !m.revoked,
                  [.dm, .group].contains(ChatKind(jid: chatJid)) {
            // Sent from another device: replying reads what came before it, even without a read-self
            // receipt; a delayed reply leaves newer incoming messages unread. Leaves `stateAt` alone
            // so a pending history snapshot still brings the chat's pin/mute/archive.
            try readMessages(db, chatJid, where: "timestamp <= ?", [m.timestamp], readAt: m.timestamp, &cs)
        }
        try applyPending(db, chatJid, m.id, &cs)
    }

    /// Sets `extra.mentions` to a JSON array argument, or removes it for NULL. Takes the value twice.
    static let setMentionsSQL = """
        extra = CASE WHEN ? IS NULL THEN json_remove(extra, '$.mentions')
                     ELSE json_set(COALESCE(extra, '{}'), '$.mentions', json(?)) END
        """

    private static func mentionsJSON(_ mentions: [String]?) throws -> String? {
        try mentions.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
    }

    /// `extra` with the text's mention list replaced; the list travels with the text it belongs to.
    private static func withMentions(_ extra: MessageExtra?, _ mentions: [String]?) -> MessageExtra? {
        var e = extra ?? MessageExtra()
        e.mentions = mentions
        return e.isEmpty ? nil : e
    }

    /// The quote keeps the list its target was shown with, so it reads the same as the target.
    private static func outgoingExtra(text: String?, mentions: [String], quoted: BridgeQuoted?) -> MessageExtra? {
        let extra = MessageExtra(location: nil, contact: nil, poll: nil, mentions: Mentions.stored(mentions, text: text),
                                 quotedMentions: quoted.flatMap { $0.mentions.isEmpty ? nil : $0.mentions })
        return extra.isEmpty ? nil : extra
    }

    private static func extra(_ m: BridgeMessage) -> MessageExtra? {
        let extra = MessageExtra(
            location: m.location.map { LocationInfo(latitude: $0.latitude, longitude: $0.longitude, name: $0.name, address: $0.address, isLive: $0.isLive) },
            contact: m.contact.map { ContactCardInfo(displayName: $0.displayName, vcard: $0.vcard) },
            poll: m.poll.map { PollInfo(question: $0.question, options: $0.options, selectableCount: Int($0.selectableCount)) },
            mentions: Mentions.stored(m.mentions, text: m.text),
            // Clients strip the quoted message's list, so an empty one says nothing (see `MessageItemFetcher`).
            quotedMentions: m.quoted.flatMap { $0.mentions.isEmpty ? nil : $0.mentions }
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
        let editedMentions = old.extra?.mentions
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
            old.extra = Self.withMentions(old.extra, editedMentions)
        } else {
            old.text = m.text
            old.editedAt = m.editedAt ?? old.editedAt
        }
        try old.update(db)
        // Alerts only while the message itself is still unread.
        if live, !old.fromMe, !old.revoked, old.kind != .system, !focus.isReading(old.chatJid),
           try Bool.fetchOne(db, sql: "SELECT unread FROM message WHERE chatJid = ? AND id = ?",
                             arguments: [old.chatJid, old.id]) == true {
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
        case .edit(let target, let text, let mentions, let editedAt, let stanza):
            try applyOrPark(db, target, .edit(text: text, mentions: Mentions.stored(mentions, text: text), editedAt: editedAt), &cs)
            try recordStanza(db, canon(target.chatJid), stanza, &cs)
        case .revoke(let target, _, let timestamp, let stanza):
            try applyOrPark(db, target, .revoke(timestamp: timestamp), &cs)
            try recordStanza(db, canon(target.chatJid), stanza, &cs)
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

    /// An edit or revoke's own message id, which a read-self receipt can list in place of its
    /// target. Remembered for a receipt still to come; one that came first reads the chat now.
    private func recordStanza(_ db: Database, _ chatJid: String, _ stanza: BridgeStanza?, _ cs: inout ChangeSet) throws {
        guard let stanza else { return }
        try Self.recordTombstone(db, chatJid, stanza.id, .addon, "", stanza.timestamp)
        guard pendingCount > 0 else { return }
        try db.execute(sql: """
            DELETE FROM pending_mutation WHERE chatJid = ? AND messageId = ? AND payload LIKE '{"readElsewhere"%'
            """, arguments: [chatJid, stanza.id])
        guard db.changesCount > 0 else { return }
        pendingCount = max(0, pendingCount - db.changesCount)
        try readMessages(db, chatJid, where: "timestamp <= ?", [stanza.timestamp], readAt: stanza.timestamp, &cs)
    }

    private func park(_ db: Database, _ chatJid: String, _ messageId: String, _ mutation: MessageMutation) throws {
        if hasMessageTombstones, try Self.tombstone(db, chatJid, messageId, .message) != nil { return }
        let payload = String(decoding: try JSONEncoder().encode(mutation), as: UTF8.self)
        try db.execute(sql: "INSERT INTO pending_mutation (chatJid, messageId, payload, createdAt) VALUES (?, ?, ?, ?)",
                       arguments: [chatJid, messageId, payload, Int64(Date().timeIntervalSince1970)])
        pendingCount += 1
    }

    /// Keeps `unreadCount` equal to the unread-flagged messages plus the unattributed count.
    private static func recountUnread(_ db: Database, _ jid: String) throws {
        try db.execute(sql: """
            UPDATE chat SET unreadCount = unreadUnattributed
                + (SELECT COUNT(*) FROM message WHERE chatJid = chat.jid AND unread)
            WHERE jid = ?
            """, arguments: [jid])
    }

    /// A read from another device, or implied by a reply: the unread messages `filter` selects,
    /// and a snapshot's unattributed count when the read, done at `readAt` (nil: covers everything),
    /// is no older than the snapshot. Withdraws the chat's notifications when nothing stays
    /// unread, else only the read messages'.
    private func readMessages(_ db: Database, _ jid: String, where filter: String, _ args: StatementArguments,
                              readAt: Int64?, _ cs: inout ChangeSet) throws {
        let ids = try String.fetchAll(db, sql: """
            UPDATE message SET unread = 0 WHERE chatJid = ? AND unread AND (\(filter)) RETURNING id
            """, arguments: [jid] + args)
        try db.execute(sql: """
            UPDATE chat SET unreadUnattributed = 0
            WHERE jid = ? AND (? IS NULL OR unreadUnattributedAt IS NULL OR unreadUnattributedAt <= ?)
            """, arguments: [jid, readAt, readAt])
        try Self.recountUnread(db, jid)
        if try Int.fetchOne(db, sql: "SELECT unreadCount FROM chat WHERE jid = ?", arguments: [jid]) ?? 0 == 0 {
            cs.chatRead(jid)
        } else {
            for id in ids { cs.removed(jid, id) }
        }
    }

    /// A read-self receipt listed it, or the phone marked the chat read through its timestamp.
    private func readElsewhere(_ db: Database, _ chatJid: String, _ m: BridgeMessage) throws -> Bool {
        if pendingCount > 0, try Bool.fetchOne(db, sql: """
            SELECT 1 FROM pending_mutation WHERE chatJid = ? AND messageId = ? AND payload LIKE '{"readElsewhere"%'
            """, arguments: [chatJid, m.id]) == true {
            return true
        }
        return try Bool.fetchOne(db, sql: "SELECT readThrough >= ? FROM chat WHERE jid = ?", arguments: [m.timestamp, chatJid]) == true
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
        case .receipt(let reader, let rank): .receipt(readerJid: canon(reader), rank: rank)
        case .edit, .revoke, .status, .rejected, .encrypted, .readElsewhere: mutation
        }
    }

    // MARK: Tombstones

    enum TombstoneKind: String {
        /// Deleted for me; `senderJid` is empty.
        case message
        /// A sender removed their reaction / cleared their vote at `timestamp`.
        case reaction, vote
        /// An edit or revoke's own message id (never stored as a message), sent at `timestamp`.
        case addon
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
        case .edit(let text, let mentions, let editedAt):
            let mentionsJSON = try Self.mentionsJSON(mentions)
            try db.execute(sql: """
                UPDATE message SET text = ?, editedAt = ?, \(Self.setMentionsSQL)
                WHERE chatJid = ? AND id = ? AND revoked = 0 AND (editedAt IS NULL OR editedAt <= ?)
                """, arguments: [text, editedAt, mentionsJSON, mentionsJSON] + key + [editedAt])
        case .revoke:
            try db.execute(sql: "UPDATE message SET revoked = 1, text = NULL WHERE chatJid = ? AND id = ?", arguments: key)
            try db.execute(sql: "DELETE FROM media WHERE chatJid = ? AND messageId = ?", arguments: key)
            // Our edits and reactions still queued for it would land on a deleted message.
            try db.execute(sql: "DELETE FROM outbox WHERE chatJid = ? AND messageId = ? AND kind IN ('edit', 'reaction')", arguments: key)
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
            let changed = db.changesCount > 0
            // In a DM, delivered/read covers every earlier sent message; the peer doesn't always
            // send a receipt per message.
            if rank >= MessageStatus.delivered.rank, ChatKind(jid: chatJid) == .dm {
                let earlier = try String.fetchAll(db, sql: """
                    UPDATE message SET status = ?
                    WHERE chatJid = ? AND fromMe = 1 AND status >= ? AND status < ?
                      AND sortKey < (SELECT sortKey FROM message WHERE chatJid = ? AND id = ? AND fromMe = 1)
                    RETURNING id
                    """, arguments: [rank, chatJid, MessageStatus.sent.rank, rank] + key)
                for id in earlier { cs.update(chatJid, id) }
            }
            guard changed else { return true }
        case .receipt(let reader, let rank):
            try applyGroupReceipt(db, chatJid, id, reader: reader, rank: rank, &cs)
            return true
        case .rejected:
            try db.execute(sql: "UPDATE message SET status = ? WHERE chatJid = ? AND id = ? AND status = ?",
                           arguments: [MessageStatus.failed.rank] + key + [MessageStatus.pending.rank])
            guard db.changesCount > 0 else { return true }
        case .encrypted:
            return false
        case .readElsewhere:
            // Stored now (just arrived, or its marker followed an alias merge): read like the receipt
            // that parked it, this message and everything before it.
            let at = try Row.fetchOne(db, sql: "SELECT sortKey, timestamp FROM message WHERE chatJid = ? AND id = ?", arguments: key)
            if let at {
                let sortKey: Int64 = at["sortKey"], timestamp: Int64 = at["timestamp"]
                try readMessages(db, chatJid, where: "sortKey <= ?", [sortKey], readAt: timestamp, &cs)
            }
            return true
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
            // Reading the listed messages read the chat up to them; newer ones stay unread. Listed
            // messages not here yet (offline delivery can bring the read first) arrive read. A listed
            // edit or revoke reads up to when it was sent.
            var newest = Int64.min, newestStanza = Int64.min
            for id in r.messageIds {
                if let key = try Int64.fetchOne(db, sql: "SELECT sortKey FROM message WHERE chatJid = ? AND id = ?",
                                                arguments: [chatJid, id]) {
                    newest = max(newest, key)
                } else if let at = try Self.tombstone(db, chatJid, id, .addon) {
                    newestStanza = max(newestStanza, at)
                } else {
                    try park(db, chatJid, id, .readElsewhere)
                }
            }
            try readMessages(db, chatJid, where: "sortKey <= ? OR timestamp <= ?", [newest, newestStanza], readAt: r.timestamp, &cs)
            try db.execute(sql: "UPDATE chat SET stateAt = ? WHERE jid = ?", arguments: [Self.now, chatJid])
            return
        case .retry, .other:
            return
        }
        let isGroupReceipt = ChatKind(jid: chatJid) == .group && status != .sent
        let reader = canon(r.senderJid)
        if isGroupReceipt {
            // We're not one of our own message's recipients.
            let own = try String.fetchSet(db, sql: "SELECT value FROM meta WHERE key IN ('ownPn', 'ownLid')")
            if own.contains(reader) || own.map(canon).contains(reader) { return }
        }
        let mutation: MessageMutation = isGroupReceipt
            ? .receipt(readerJid: reader, rank: status.rank)
            : .status(rank: status.rank)
        for id in r.messageIds {
            if try !applyMutation(db, chatJid, id, mutation, &cs) {
                try park(db, chatJid, id, mutation)
            }
        }
    }

    /// Records a member's receipt for our group message. Receipts don't list every message, so a
    /// reader's rank also covers our earlier sent messages back to their first receipt here (before
    /// that they may not have been a member). Invariant, per reader and rank: every sent message
    /// from their first receipt to their furthest receipt at that rank holds a row at that rank or
    /// higher, so each receipt only fills what it newly covers.
    private func applyGroupReceipt(_ db: Database, _ chatJid: String, _ id: String, reader: String, rank: Int,
                                   _ cs: inout ChangeSet) throws {
        guard let target = try Int64.fetchOne(db, sql: "SELECT sortKey FROM message WHERE chatJid = ? AND id = ? AND fromMe = 1",
                                              arguments: [chatJid, id]) else { return }
        let base: StatementArguments = [chatJid, reader]
        let first = try Int64.fetchOne(db, sql: "SELECT MIN(sortKey) FROM receipt WHERE chatJid = ? AND readerJid = ?", arguments: base)
        let reached = try (rank...MessageStatus.read.rank).compactMap { r in
            try Int64.fetchOne(db, sql: "SELECT MAX(sortKey) FROM receipt WHERE chatJid = ? AND readerJid = ? AND rank = ?",
                               arguments: base + [r])
        }.max()
        var touched: Set<String> = []
        func fill(_ lo: Int64, _ hi: Int64, _ rank: Int, sentOnly: Bool = true) throws {
            guard lo <= hi else { return }
            touched.formUnion(try String.fetchAll(db, sql: """
                INSERT INTO receipt (chatJid, messageId, readerJid, rank, sortKey)
                SELECT chatJid, id, ?, ?, sortKey FROM message
                WHERE chatJid = ? AND sortKey BETWEEN ? AND ? AND fromMe = 1 AND status >= ?
                ON CONFLICT DO UPDATE SET rank = excluded.rank WHERE rank < excluded.rank
                RETURNING messageId
                """, arguments: [reader, rank, chatJid, lo, hi, sentOnly ? MessageStatus.sent.rank : MessageStatus.failed.rank]))
        }
        // The target itself was received, whatever its local state.
        try fill(target, target, rank, sentOnly: false)
        if let first, target < first {
            // An earlier first receipt: everything up to the old one takes the reader's highest rank.
            let top = try Int.fetchOne(db, sql: "SELECT MAX(rank) FROM receipt WHERE chatJid = ? AND readerJid = ?", arguments: base) ?? rank
            try fill(target, first - 1, max(rank, top))
        } else if let reached, target > reached {
            try fill(reached + 1, target, rank)
        } else if reached == nil, let first {
            try fill(first, target, rank)
        }
        for messageId in touched { try settleGroupStatus(db, chatJid, messageId, &cs) }
    }

    /// The ack's chat can be missing or spelled differently from ours (a DM's LID), so an id that
    /// only one of our messages has finds it too. An ack that beats `completeSend` (the row still
    /// has its local id) is parked for it; reactions, edits and revokes are acked too, and those
    /// aren't kept unless a send is in flight.
    private func handleServerAck(_ ack: BridgeServerAck, _ db: Database, _ cs: inout ChangeSet) throws {
        let mutation: MessageMutation = ack.error == nil ? .status(rank: MessageStatus.sent.rank) : .rejected
        if ack.error != nil { WAKit.log.error("server rejected \(ack.messageId, privacy: .public): \(ack.error ?? "", privacy: .public)") }
        let ackChat = ack.chatJid.map(canon)
        if let ackChat, try applyMutation(db, ackChat, ack.messageId, mutation, &cs) { return }
        let chats = try String.fetchAll(db, sql: "SELECT chatJid FROM message WHERE id = ? AND fromMe = 1 LIMIT 2",
                                        arguments: [ack.messageId])
        if chats.count == 1 {
            try applyMutation(db, chats[0], ack.messageId, mutation, &cs)
            return
        }
        guard chats.isEmpty, try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM message WHERE fromMe = 1 AND status = ? AND id LIKE 'local-%')
            """, arguments: [MessageStatus.pending.rank]) == true else { return }
        try park(db, ackChat ?? "", ack.messageId, mutation)
    }

    /// Sends interrupted before the server gave them an id (the app quit mid-send) can't be told
    /// apart from ones never sent: they fail, for a manual retry. Runs at launch, before any send.
    static func failInterruptedSends(_ database: AppDatabase) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE message SET status = ? WHERE status = ? AND id LIKE 'local-%'",
                           arguments: [MessageStatus.failed.rank, MessageStatus.pending.rank])
        }
    }

    /// Acks parked without a chat, once no send is in flight to claim them.
    public func dropUnclaimedAcks() throws {
        try perform { db, _ in
            let inFlight = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM message WHERE fromMe = 1 AND status = ? AND id LIKE 'local-%')
                """, arguments: [MessageStatus.pending.rank]) ?? false
            guard !inFlight, self.pendingCount > 0 else { return }
            try db.execute(sql: "DELETE FROM pending_mutation WHERE chatJid = ''")
            self.pendingCount = max(0, self.pendingCount - db.changesCount)
        }
    }

    /// A resent media message was uploaded again: recipients download the new copy. Our own file
    /// and its state stay as they are.
    public func refreshSentMedia(chatJid: String, id: String, media m: BridgeMedia) throws {
        try perform { db, _ in
            try db.execute(sql: """
                UPDATE media SET directPath = ?, mediaKey = ?, fileEncSha256 = ?, fileLength = ?
                WHERE chatJid = ? AND messageId = ?
                """, arguments: [m.directPath, m.mediaKey, m.fileEncSha256, Int64(m.fileLength), chatJid, id])
        }
    }

    /// Whether our message is still waiting for the server's ack.
    public func isUnacked(chatJid: String, id: String) throws -> Bool {
        try database.pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT status = ? FROM message WHERE chatJid = ? AND id = ?",
                              arguments: [MessageStatus.pending.rank, chatJid, id]) ?? false
        }
    }

    /// Our messages written to the server but never acked (the connection died under them), with
    /// the key of the message each quotes. Oldest first.
    public func unackedSends() throws -> [(item: MessageItem, quoted: BridgeMessageKey?)] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT chatJid, id FROM message
                WHERE sentHere = 1 AND status = ? AND id NOT LIKE 'local-%' AND revoked = 0
                ORDER BY sortKey
                """, arguments: [MessageStatus.pending.rank])
            return try rows.compactMap { row -> (MessageItem, BridgeMessageKey?)? in
                let chatJid: String = row["chatJid"]
                guard let item = try MessageItemFetcher.items(db, chatJid: chatJid, ids: [row["id"]]).first else { return nil }
                return (item, try Self.quotedKey(db, item.message))
            }
        }
    }

    /// Key of the message `m` quotes, for sending the quote again.
    public func quotedKey(of m: MessageRecord) throws -> BridgeMessageKey? {
        try database.pool.read { db in try Self.quotedKey(db, m) }
    }

    static func quotedKey(_ db: Database, _ m: MessageRecord) throws -> BridgeMessageKey? {
        guard let quotedId = m.quotedId else { return nil }
        if let quoted = try MessageRecord.fetchOne(db, key: ["chatJid": m.chatJid, "id": quotedId]) { return quoted.key }
        let own = try String.fetchSet(db, sql: "SELECT value FROM meta WHERE key IN ('ownPn', 'ownLid')")
        let fromMe = m.quotedSenderJid.map(own.contains) ?? false
        return BridgeMessageKey(chatJid: m.chatJid, id: quotedId, fromMe: fromMe,
                                participant: ChatKind(jid: m.chatJid) == .group ? m.quotedSenderJid : nil)
    }

    /// Our group message becomes delivered/read once every recipient has reached that rank.
    /// Recipients are the other members when it was sent, else now; until the group's size is
    /// known it stays as it is (`handleGroup` settles it then).
    private func settleGroupStatus(_ db: Database, _ chatJid: String, _ id: String, _ cs: inout ChangeSet) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT MAX(1, COALESCE(m.recipientCount, c.participantCount - 1)) AS needed,
                   (SELECT COUNT(*) FROM receipt WHERE chatJid = m.chatJid AND messageId = m.id AND rank >= ?1) AS delivered,
                   (SELECT COUNT(*) FROM receipt WHERE chatJid = m.chatJid AND messageId = m.id AND rank >= ?2) AS read
            FROM message m LEFT JOIN chat c ON c.jid = m.chatJid
            WHERE m.chatJid = ?3 AND m.id = ?4
            """, arguments: [MessageStatus.delivered.rank, MessageStatus.read.rank, chatJid, id]),
              let needed: Int = row["needed"] else { return }
        let status: MessageStatus? = row["read"] >= needed ? .read : row["delivered"] >= needed ? .delivered : nil
        guard let status else { return }
        try db.execute(sql: "UPDATE message SET status = ? WHERE chatJid = ? AND id = ? AND status < ?",
                       arguments: [status.rank, chatJid, id, status.rank])
        if db.changesCount > 0 { cs.update(chatJid, id) }
    }

    /// Records how many other members a group had when we sent a message to it.
    private func stampRecipients(_ db: Database, _ chatJid: String, _ id: String) throws {
        guard ChatKind(jid: chatJid) == .group else { return }
        try db.execute(sql: """
            UPDATE message SET recipientCount = (SELECT participantCount - 1 FROM chat WHERE jid = ?1 AND participantCount > 1)
            WHERE chatJid = ?1 AND id = ?2
            """, arguments: [chatJid, id])
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
            INSERT INTO chat (jid, kind, name, lastActivityAt, markedUnread, pinnedAt, mutedUntil, archived, readOnly)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(jid) DO UPDATE SET
                name = COALESCE(excluded.name, name),
                lastActivityAt = CASE
                    WHEN excluded.lastActivityAt IS NULL THEN lastActivityAt
                    WHEN lastActivityAt IS NULL THEN excluded.lastActivityAt
                    ELSE MAX(lastActivityAt, excluded.lastActivityAt) END,
                markedUnread = CASE WHEN stateAt IS NULL THEN excluded.markedUnread ELSE markedUnread END,
                pinnedAt = CASE WHEN stateAt IS NULL THEN excluded.pinnedAt ELSE pinnedAt END,
                mutedUntil = CASE WHEN stateAt IS NULL THEN excluded.mutedUntil ELSE mutedUntil END,
                archived = CASE WHEN stateAt IS NULL THEN excluded.archived ELSE archived END,
                readOnly = excluded.readOnly
            """, arguments: [jid, c.kind, c.name, c.lastActivityAt, c.markedUnread,
                             c.pinnedAt, c.mutedUntil, c.archived, c.readOnly])
        if c.kind == .dm { try ensureContact(db, jid) }
    }

    /// A snapshot counts the chat's unread without naming them: they were its newest incoming
    /// messages then. Runs after the chunk's messages are stored; flags those, and keeps the rest
    /// as unattributed, dated by the snapshot's newest activity. Only while no read or chat action
    /// here has superseded the snapshot (`stateAt`), like the rest of its state.
    private func attributeSnapshotUnread(_ c: BridgeChat, _ db: Database) throws {
        let jid = canon(c.jid)
        guard c.unreadCount > 0,
              try Bool.fetchOne(db, sql: "SELECT stateAt IS NULL FROM chat WHERE jid = ?", arguments: [jid]) == true
        else { return }
        let window: StatementArguments = [jid, c.lastActivityAt, c.lastActivityAt, Int(c.unreadCount)]
        let windowSQL = """
            SELECT localId FROM message WHERE chatJid = ? AND fromMe = 0 AND kind != 'system'
              AND (? IS NULL OR timestamp <= ?)
            ORDER BY sortKey DESC LIMIT ?
            """
        try db.execute(sql: "UPDATE message SET unread = 1 WHERE localId IN (\(windowSQL))", arguments: window)
        let stored = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (\(windowSQL))", arguments: window) ?? 0
        let missing = Int(c.unreadCount) - stored
        if missing > 0 {
            try db.execute(sql: """
                UPDATE chat SET unreadUnattributed = MAX(unreadUnattributed, ?),
                    unreadUnattributedAt = MAX(COALESCE(unreadUnattributedAt, 0), COALESCE(?, 0))
                WHERE jid = ?
                """, arguments: [missing, c.lastActivityAt, jid])
        }
        try Self.recountUnread(db, jid)
    }

    /// `local`: made here (`applyLocal`). One from another device replaces any of ours of the same
    /// kind still queued for the chat.
    private func handleChatAction(_ action: BridgeChatAction, local: Bool = false, _ db: Database, _ cs: inout ChangeSet) throws {
        if !local, let (jid, change) = try outboxChange(for: action, db), let on = change.chatActionValue {
            let key = change.kind + " " + jid
            // Ours carry no read range; a read with one is another device's.
            var ranged = false
            if case .markRead(_, _, let readThrough, _) = action, readThrough != nil { ranged = true }
            if !ranged, let echo = echoes[key], echo.on == on, ContinuousClock.now - echo.at < .seconds(60) {
                // Our own action replayed by the library's re-sync: this Mac has it, or something newer.
                echoes[key] = nil
                return
            }
            try db.execute(sql: "DELETE FROM outbox WHERE kind = ? AND chatJid = ?", arguments: [change.kind, jid])
        }
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
        case .markRead(let jid, let read, let readThrough, let readAt):
            let jid = canon(jid)
            // The boundary must outlive a chat whose first message has not arrived yet.
            if read, readThrough != nil { try ensureChat(db, jid) }
            if read {
                // Up to the synced range, else to when it was done (an echo of ours then spares
                // what arrived since); our own read, with neither, covers everything.
                let upTo = readThrough ?? readAt
                try readMessages(db, jid, where: "? IS NULL OR timestamp <= ?", [upTo, upTo], readAt: upTo, &cs)
                try db.execute(sql: """
                    UPDATE chat SET markedUnread = 0, stateAt = ?,
                        readThrough = CASE WHEN ? IS NULL THEN readThrough ELSE MAX(COALESCE(readThrough, 0), ?) END
                    WHERE jid = ?
                    """, arguments: [Self.now, readThrough, readThrough, jid])
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
            try Self.recountUnread(db, jid)
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
        // The unattributed messages are not stored: gone only if the clear reaches the snapshot.
        try db.execute(sql: """
            UPDATE chat SET unreadUnattributed = 0
            WHERE jid = ? AND (? IS NULL OR unreadUnattributedAt IS NULL OR unreadUnattributedAt <= ?)
            """, arguments: [jid, cutoff, cutoff])
        try Self.recountUnread(db, jid)
        cs.reload.insert(jid)
        cs.dirty.insert(jid)
    }

    private func handleGroup(_ g: BridgeGroup, _ db: Database, _ cs: inout ChangeSet) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO chat (jid, kind) VALUES (?, 'group')", arguments: [g.jid])
        // A zero count is unknown: keep the stored one, except that a membership change
        // (`membershipChanged`) makes it stale, so it is cleared for `GroupService` to re-fetch.
        let count: Int? = g.participantCount > 0 ? Int(g.participantCount) : nil
        let stale = g.membershipChanged && count == nil
        let sizeWasUnknown = try Int.fetchOne(db, sql: "SELECT participantCount FROM chat WHERE jid = ?", arguments: [g.jid]) == nil
        try db.execute(sql: """
            UPDATE chat SET name = COALESCE(?, name),
                participantCount = CASE WHEN ? IS NOT NULL THEN ? WHEN ? THEN NULL ELSE participantCount END
            WHERE jid = ?
            """, arguments: [g.subject.nonEmpty, count, count, stale, g.jid])
        if g.isCommunity {
            // A community itself is not a chat: unlisted, even if a join listed it first.
            try db.execute(sql: """
                UPDATE chat SET lastActivityAt = NULL WHERE jid = ? AND NOT EXISTS (SELECT 1 FROM message WHERE chatJid = ?)
                """, arguments: [g.jid, g.jid])
        } else if let joinedAt = g.joinedAt {
            // Listed from the join on, before anyone writes in it.
            try db.execute(sql: "UPDATE chat SET lastActivityAt = MAX(COALESCE(lastActivityAt, 0), ?) WHERE jid = ?",
                           arguments: [joinedAt, g.jid])
        }
        if count != nil, sizeWasUnknown {
            // Our messages that were waiting on the group's size.
            let waiting = try String.fetchAll(db, sql: """
                SELECT DISTINCT r.messageId FROM receipt r JOIN message m ON m.chatJid = r.chatJid AND m.id = r.messageId
                WHERE r.chatJid = ? AND m.recipientCount IS NULL AND m.status < ?
                """, arguments: [g.jid, MessageStatus.read.rank])
            for id in waiting { try settleGroupStatus(db, g.jid, id, &cs) }
        }
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
        var resolver = try Mentions.Resolver(db)
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
                senderName: sender, kind: m.kind,
                text: try m.text.map { Mentions.apply($0, try resolver.mentions(in: $0, jids: m.extra?.mentions)) },
                timestamp: m.timestamp,
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
                INSERT INTO contact (jid, fullName, firstName, pushName, phone, isBusiness, businessCheckedAt, verifiedName)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(jid) DO UPDATE SET
                    fullName = COALESCE(fullName, excluded.fullName),
                    firstName = COALESCE(firstName, excluded.firstName),
                    pushName = COALESCE(pushName, excluded.pushName),
                    phone = COALESCE(phone, excluded.phone),
                    isBusiness = isBusiness OR excluded.isBusiness,
                    businessCheckedAt = COALESCE(businessCheckedAt, excluded.businessCheckedAt),
                    verifiedName = COALESCE(verifiedName, excluded.verifiedName)
                """, arguments: [pn, lc.fullName, lc.firstName, lc.pushName, lc.phone, lc.isBusiness, lc.businessCheckedAt, lc.verifiedName])
            // The LID's picture is in a file named after it; a phone number checked as having none
            // (without the privacy token the LID was asked with) is asked again.
            try db.execute(sql: """
                UPDATE contact SET avatarCheckedAt = NULL
                WHERE jid = ? AND hasAvatar = 0 AND EXISTS (SELECT 1 FROM contact WHERE jid = ? AND hasAvatar)
                """, arguments: [pn, lid])
            try db.execute(sql: "DELETE FROM contact WHERE jid = ?", arguments: [lid])
        }

        // Chat and its messages
        if let lidChat = try ChatRecord.fetchOne(db, key: lid) {
            if let pnChat = try ChatRecord.fetchOne(db, key: pn) {
                let boundary = try Int64.fetchOne(db, sql: "SELECT MAX(readThrough) FROM chat WHERE jid IN (?, ?)", arguments: [lid, pn])
                let lidDebt = try Row.fetchOne(db, sql: "SELECT unreadUnattributed, unreadUnattributedAt FROM chat WHERE jid = ?", arguments: [lid])
                let lidUnattributed: Int = lidDebt?["unreadUnattributed"] ?? 0
                let lidUnattributedAt: Int64? = lidDebt?["unreadUnattributedAt"]
                // A message under both JIDs is unread if either copy is; the PN copy is kept.
                try db.execute(sql: """
                    UPDATE message SET unread = 1 WHERE chatJid = ? AND NOT unread
                      AND id IN (SELECT id FROM message WHERE chatJid = ? AND unread)
                    """, arguments: [pn, lid])
                let dupIds = try String.fetchAll(db, sql: """
                    SELECT l.id FROM message l JOIN message p ON p.chatJid = ? AND p.id = l.id WHERE l.chatJid = ?
                    """, arguments: [pn, lid])
                for id in dupIds { try reconcileDuplicate(id, from: lid, into: pn, db) }
                let lidStateAt = try Int64.fetchOne(db, sql: "SELECT stateAt FROM chat WHERE jid = ?", arguments: [lid])
                try db.execute(sql: """
                    UPDATE chat SET
                        name = COALESCE(name, ?),
                        stateAt = CASE WHEN ? IS NULL THEN stateAt ELSE MAX(COALESCE(stateAt, 0), ?) END,
                        readThrough = ?,
                        -- Two snapshots of one chat: their unattributed counts likely name the same messages.
                        unreadUnattributed = MAX(unreadUnattributed, ?),
                        unreadUnattributedAt = CASE WHEN ? IS NULL THEN unreadUnattributedAt
                            ELSE MAX(COALESCE(unreadUnattributedAt, 0), ?) END,
                        markedUnread = markedUnread OR ?,
                        pinnedAt = COALESCE(pinnedAt, ?),
                        mutedUntil = COALESCE(mutedUntil, ?),
                        archived = ?,
                        avatarCheckedAt = CASE WHEN hasAvatar THEN avatarCheckedAt ELSE NULL END,
                        lastActivityAt = MAX(COALESCE(lastActivityAt, 0), COALESCE(?, 0))
                    WHERE jid = ?
                    """, arguments: [lidChat.name, lidStateAt, lidStateAt, boundary, lidUnattributed, lidUnattributedAt, lidUnattributedAt, lidChat.markedUnread, lidChat.pinnedAt,
                                     lidChat.mutedUntil, pnChat.archived && lidChat.archived,
                                     lidChat.lastActivityAt, pn])
                // Duplicates (same id under both JIDs), now reconciled into the PN copy, stay behind
                // and are deleted with the LID chat.
                try db.execute(sql: "UPDATE OR IGNORE message SET chatJid = ? WHERE chatJid = ?", arguments: [pn, lid])
                try db.execute(sql: "UPDATE OR IGNORE chat_tag SET chatJid = ? WHERE chatJid = ?", arguments: [pn, lid])
                try db.execute(sql: "DELETE FROM chat WHERE jid = ?", arguments: [lid])
                // What either side's read boundary covers is read in the merged chat.
                if let boundary {
                    try readMessages(db, pn, where: "timestamp <= ?", [boundary], readAt: boundary, &cs)
                } else {
                    try Self.recountUnread(db, pn)
                }
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
        try db.execute(sql: """
            INSERT INTO receipt (chatJid, messageId, readerJid, rank, sortKey)
            SELECT chatJid, messageId, ?2, rank, sortKey FROM receipt WHERE readerJid = ?1
            ON CONFLICT DO UPDATE SET rank = MAX(rank, excluded.rank)
            """, arguments: [lid, pn])
        try db.execute(sql: "DELETE FROM receipt WHERE readerJid = ?", arguments: [lid])
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

        // Where both JIDs have a row for the same change, the newer one stays.
        try db.execute(sql: """
            DELETE FROM outbox WHERE chatJid = ?1 AND EXISTS (
                SELECT 1 FROM outbox l WHERE l.chatJid = ?2 AND l.kind = outbox.kind AND l.messageId = outbox.messageId AND l.id > outbox.id)
            """, arguments: [pn, lid])
        try db.execute(sql: "UPDATE OR IGNORE outbox SET chatJid = ? WHERE chatJid = ?", arguments: [pn, lid])
        try db.execute(sql: "DELETE FROM outbox WHERE chatJid = ?", arguments: [lid])

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
            p.extra = Self.withMentions(p.extra, l.extra?.mentions)
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
