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

    private nonisolated let queue = DispatchSerialQueue(label: "BetterWA.ingest", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// LID → phone-number JID.
    private var aliases: [String: String]
    private var ingestSeq: Int64
    private var persistedSeq: Int64
    private var pendingCount: Int

    static let maxAddsBeforeReload = 300

    public init(database: AppDatabase, feed: MessageChangeFeed = MessageChangeFeed(), focus: ChatFocus = ChatFocus()) throws {
        self.database = database
        self.feed = feed
        self.focus = focus
        let (aliases, seq, pending) = try database.pool.read { db in
            let a = try JidAliasRecord.fetchAll(db)
            let s = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'ingestSeq'").flatMap { Int64($0) } ?? 0
            let p = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_mutation") ?? 0
            return (Dictionary(a.map { ($0.lid, $0.pn) }, uniquingKeysWith: { _, b in b }), s, p)
        }
        self.aliases = aliases
        self.ingestSeq = seq
        self.persistedSeq = seq
        self.pendingCount = pending
    }

    // MARK: - Public entry points

    /// Applies one bridge batch in a single transaction. Session-only events are ignored here.
    public func apply(_ events: [BridgeEvent]) throws {
        _ = try applyBatch(events)
    }

    /// `apply`, returning the incoming messages read in the focused chat (per chat) to mark read.
    func applyBatch(_ events: [BridgeEvent]) throws -> [String: [BridgeMessageKey]] {
        try perform { db, cs in
            for event in events { try self.handle(event, db, &cs) }
            return cs.readWhileFocused
        }
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
        return try perform { db, _ in
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
                    isAnimated: media.kind == .gif ? true : nil, localPath: media.filePath, downloadState: .downloaded
                ).insert(db)
            }
            try db.execute(sql: "UPDATE chat SET lastActivityAt = MAX(COALESCE(lastActivityAt, 0), ?) WHERE jid = ?", arguments: [now, jid])
            cs.add(jid, localId)
            return try MessageItemFetcher.items(db, chatJid: jid, ids: [localId])[0]
        }
    }

    /// Swaps the optimistic row for the server's id and marks it sent.
    /// `storedPath` is where the sent file now lives (the media store's copy); defaults to the source.
    public func completeSend(localId: String, chatJid: String, result: BridgeSendResult, storedPath: String? = nil) throws {
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
            let localPath = try storedPath
                ?? String.fetchOne(db, sql: "SELECT localPath FROM media WHERE chatJid = ? AND messageId = ?", arguments: [jid, localId])
            try db.execute(sql: """
                UPDATE message SET id = ?, timestamp = ?, status = MAX(status, ?) WHERE chatJid = ? AND id = ?
                """, arguments: [newId, result.timestamp, MessageStatus.sent.rank, jid, localId])
            if let media = result.message.media {
                var rec = Self.mediaRecord(media, chatJid: jid, messageId: newId)
                rec.localPath = localPath
                rec.downloadState = localPath == nil ? .none : .downloaded
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

    public func setAvatar(jid: String, path: String?, checkedAt: Int64) throws {
        let jid = canon(jid)
        try perform { db, _ in
            try db.execute(sql: "UPDATE chat SET avatarPath = ?, avatarCheckedAt = ? WHERE jid = ?", arguments: [path, checkedAt, jid])
        }
    }

    public func setMediaState(chatJid: String, messageId: String, state: MediaDownloadState, localPath: String?) throws {
        let jid = canon(chatJid)
        try perform { db, cs in
            try db.execute(sql: "UPDATE media SET downloadState = ?, localPath = COALESCE(?, localPath) WHERE chatJid = ? AND messageId = ?",
                           arguments: [state, localPath, jid, messageId])
            if db.changesCount > 0 { cs.update(jid, messageId) }
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
    private func perform<T>(_ body: (Database, inout ChangeSet) throws -> T) throws -> T {
        var cs = ChangeSet()
        let saved = (aliases, ingestSeq, persistedSeq, pendingCount)
        let result: T
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
            try db.execute(sql: "UPDATE chat SET avatarPath = NULL, avatarCheckedAt = NULL WHERE jid = ?", arguments: [canon(jid)])
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
        try db.execute(sql: "INSERT OR IGNORE INTO chat (jid, kind) VALUES (?, ?)", arguments: [jid, ChatKind(jid: jid)])
    }

    // MARK: Messages

    private func upsertMessage(_ m: BridgeMessage, live: Bool, _ db: Database, _ cs: inout ChangeSet) throws {
        let chatJid = canon(m.chatJid)
        let sender = canon(m.senderJid)
        try ensureChat(db, chatJid)

        if !m.fromMe, let name = m.pushName, !name.isEmpty, !sender.isEmpty { cs.pushNames[sender] = name }

        let existing = try MessageRecord.fetchOne(db, sql: "SELECT * FROM message WHERE chatJid = ? AND id = ?",
                                                  arguments: [chatJid, m.id])
        let incomingStatus = m.status.map { MessageStatus(rank: $0.rank) }
        if var old = existing {
            if old.kind == .undecryptable, m.kind != .undecryptable {
                try upgradePlaceholder(&old, with: m, status: incomingStatus, db, &cs)
                return
            }
            // Re-delivery (history after live, or our own send echoed): merge forward-only fields.
            var sets: [String] = []
            var args: [any DatabaseValueConvertible] = []
            if let s = incomingStatus, s.rank > old.status.rank { sets.append("status = ?"); args.append(s.rank) }
            if m.revoked, !old.revoked { sets.append("revoked = 1, text = NULL") }
            if let e = m.editedAt, e > (old.editedAt ?? 0), !m.revoked, !old.revoked {
                sets.append("text = ?, editedAt = ?"); args.append(m.text); args.append(e)
            }
            if !sets.isEmpty {
                try db.execute(sql: "UPDATE message SET \(sets.joined(separator: ", ")) WHERE chatJid = ? AND id = ?",
                               arguments: StatementArguments(args + [chatJid, m.id]))
                cs.update(chatJid, m.id)
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
            try ReactionRecord(chatJid: chatJid, messageId: m.id, senderJid: canon(r.senderJid), emoji: r.emoji,
                               fromMe: r.fromMe, timestamp: r.timestamp).upsert(db)
        }
        cs.add(chatJid, m.id)

        if live, !m.fromMe, m.kind != .system, !m.revoked {
            if focus.isReading(chatJid) {
                cs.readWhileFocused[chatJid, default: []].append(rec.key)
            } else {
                try db.execute(sql: "UPDATE chat SET unreadCount = unreadCount + 1 WHERE jid = ?", arguments: [chatJid])
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
    private func upgradePlaceholder(_ old: inout MessageRecord, with m: BridgeMessage, status: MessageStatus?,
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
        }
    }

    private func applyOrPark(_ db: Database, _ target: BridgeMessageKey, _ mutation: MessageMutation, _ cs: inout ChangeSet) throws {
        let chatJid = canon(target.chatJid)
        if try !applyMutation(db, chatJid, target.id, mutation, &cs) {
            try park(db, chatJid, target.id, mutation)
        }
    }

    private func park(_ db: Database, _ chatJid: String, _ messageId: String, _ mutation: MessageMutation) throws {
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
        for row in rows {
            let payload: String = row["payload"]
            if let mutation = try? JSONDecoder().decode(MessageMutation.self, from: Data(payload.utf8)) {
                try applyMutation(db, chatJid, messageId, canonicalised(mutation), &cs)
            }
        }
        try db.execute(sql: "DELETE FROM pending_mutation WHERE chatJid = ? AND messageId = ?", arguments: [chatJid, messageId])
        pendingCount = max(0, pendingCount - rows.count)
    }

    /// Parked mutations keep the sender JID they arrived with; an alias learned since then applies.
    private func canonicalised(_ mutation: MessageMutation) -> MessageMutation {
        switch mutation {
        case .reaction(let sender, let fromMe, let emoji, let ts): .reaction(senderJid: canon(sender), fromMe: fromMe, emoji: emoji, timestamp: ts)
        case .pollVote(let voter, let selected, let ts): .pollVote(voterJid: canon(voter), selected: selected, timestamp: ts)
        case .edit, .revoke, .status: mutation
        }
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
        case .reaction(let sender, let fromMe, let emoji, let ts):
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
            }
        case .clear(let jid, let cutoff):
            try clearMessages(canon(jid), upTo: cutoff, db, &cs)
        case .deleteMessageForMe(let target):
            let jid = canon(target.chatJid)
            try db.execute(sql: "DELETE FROM message WHERE chatJid = ? AND id = ?", arguments: [jid, target.id])
            if db.changesCount > 0 { cs.delete(jid, target.id) }
        }
    }

    /// Deletes messages at or before `cutoff` (all when nil); unread never exceeds what is left.
    private func clearMessages(_ jid: String, upTo cutoff: Int64?, _ db: Database, _ cs: inout ChangeSet) throws {
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
        try db.execute(sql: "UPDATE chat SET name = COALESCE(?, name), participantCount = ? WHERE jid = ?",
                       arguments: [g.subject.nonEmpty, Int(g.participantCount), g.jid])
        guard !g.participants.isEmpty else { return }
        try db.execute(sql: "DELETE FROM group_participant WHERE groupJid = ?", arguments: [g.jid])
        for p in g.participants {
            try GroupParticipantRecord(groupJid: g.jid, jid: canon(p.jid), isAdmin: p.isAdmin, isSuperAdmin: p.isSuperAdmin)
                .insert(db, onConflict: .replace)
        }
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
        try JidAliasRecord(lid: lid, pn: pn).upsert(db)

        // Contacts
        if let lc = try ContactRecord.fetchOne(db, key: lid) {
            try db.execute(sql: """
                INSERT INTO contact (jid, fullName, firstName, pushName, phone) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(jid) DO UPDATE SET
                    fullName = COALESCE(fullName, excluded.fullName),
                    firstName = COALESCE(firstName, excluded.firstName),
                    pushName = COALESCE(pushName, excluded.pushName),
                    phone = COALESCE(phone, excluded.phone)
                """, arguments: [pn, lc.fullName, lc.firstName, lc.pushName, lc.phone])
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
                        avatarPath = COALESCE(avatarPath, ?),
                        lastActivityAt = MAX(COALESCE(lastActivityAt, 0), COALESCE(?, 0))
                    WHERE jid = ?
                    """, arguments: [lidChat.name, lidStateAt, lidStateAt, max(0, lidChat.unreadCount - overlap), lidChat.markedUnread, lidChat.pinnedAt,
                                     lidChat.mutedUntil, pnChat.archived && lidChat.archived, lidChat.avatarPath,
                                     lidChat.lastActivityAt, pn])
                // Duplicates (same id under both JIDs), now reconciled into the PN copy, stay behind
                // and are deleted with the LID chat.
                try db.execute(sql: "UPDATE OR IGNORE message SET chatJid = ? WHERE chatJid = ?", arguments: [pn, lid])
                try db.execute(sql: "UPDATE OR IGNORE chat_tag SET chatJid = ? WHERE chatJid = ?", arguments: [pn, lid])
                try db.execute(sql: "DELETE FROM chat WHERE jid = ?", arguments: [lid])
            } else {
                // ON UPDATE CASCADE carries messages, media, reactions, votes and tags along.
                try db.execute(sql: "UPDATE chat SET jid = ? WHERE jid = ?", arguments: [pn, lid])
            }
            cs.reload.formUnion([lid, pn])
            cs.dirty.insert(pn)
        }

        try db.execute(sql: "UPDATE message SET senderJid = ? WHERE senderJid = ?", arguments: [pn, lid])
        try db.execute(sql: "UPDATE chat SET lastMessageSenderJid = ? WHERE lastMessageSenderJid = ?", arguments: [pn, lid])
        try db.execute(sql: "UPDATE OR REPLACE reaction SET senderJid = ? WHERE senderJid = ?", arguments: [pn, lid])
        try db.execute(sql: "UPDATE OR REPLACE poll_vote SET voterJid = ? WHERE voterJid = ?", arguments: [pn, lid])
        try db.execute(sql: "UPDATE OR REPLACE group_participant SET jid = ? WHERE jid = ?", arguments: [pn, lid])

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
            isAnimated: m.isAnimated, localPath: nil, downloadState: .none
        )
    }
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
