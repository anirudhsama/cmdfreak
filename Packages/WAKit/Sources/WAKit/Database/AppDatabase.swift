import Foundation
import GRDB

/// The app's GRDB database (`app.sqlite`, WAL). Reads go through `reader`; every write goes through `IngestActor`.
public final class AppDatabase: Sendable {
    public let pool: DatabasePool
    public var reader: any DatabaseReader { pool }

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        pool = try DatabasePool(path: url.path, configuration: config)
        try Self.migrator.migrate(pool)
    }

    public static var defaultURL: URL {
        WAKit.dataDirectory.appending(path: "app.sqlite")
    }

    public static func openDefault() throws -> AppDatabase {
        try AppDatabase(url: defaultURL)
    }
}

// MARK: - Migrations (append-only)

extension AppDatabase {
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1") { db in
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }

            try db.create(table: "chat") { t in
                t.primaryKey("jid", .text)
                t.column("kind", .text).notNull()
                t.column("name", .text)
                t.column("lastActivityAt", .integer)
                t.column("unreadCount", .integer).notNull().defaults(to: 0)
                t.column("markedUnread", .boolean).notNull().defaults(to: false)
                t.column("pinnedAt", .integer)
                t.column("mutedUntil", .integer)
                t.column("archived", .boolean).notNull().defaults(to: false)
                t.column("readOnly", .boolean).notNull().defaults(to: false)
                t.column("participantCount", .integer)
                t.column("avatarPath", .text)
                t.column("avatarCheckedAt", .integer)
                // Denormalised last-message preview, kept in sync by IngestActor so the chat list
                // observation never has to track the message table.
                t.column("lastMessageId", .text)
                t.column("lastMessageKind", .text)
                t.column("lastMessageText", .text)
                t.column("lastMessageFromMe", .boolean)
                t.column("lastMessageSenderJid", .text)
                t.column("lastMessageStatus", .integer)
                t.column("lastMessageRevoked", .boolean)
            }
            try db.create(index: "chat_on_order", on: "chat", columns: ["archived", "pinnedAt", "lastActivityAt"])

            try db.create(table: "contact") { t in
                t.primaryKey("jid", .text)
                t.column("fullName", .text)
                t.column("firstName", .text)
                t.column("pushName", .text)
                t.column("phone", .text)
            }

            try db.create(table: "group_participant") { t in
                t.column("groupJid", .text).notNull()
                t.column("jid", .text).notNull()
                t.column("isAdmin", .boolean).notNull().defaults(to: false)
                t.column("isSuperAdmin", .boolean).notNull().defaults(to: false)
                t.primaryKey(["groupJid", "jid"])
            }

            try db.create(table: "message") { t in
                t.autoIncrementedPrimaryKey("localId")
                t.column("chatJid", .text).notNull()
                    .references("chat", column: "jid", onDelete: .cascade, onUpdate: .cascade)
                t.column("id", .text).notNull()
                t.column("senderJid", .text).notNull()
                t.column("participant", .text)
                t.column("fromMe", .boolean).notNull()
                t.column("timestamp", .integer).notNull()
                t.column("sortKey", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("text", .text)
                t.column("quotedId", .text)
                t.column("quotedSenderJid", .text)
                t.column("quotedKind", .text)
                t.column("quotedSnippet", .text)
                t.column("status", .integer).notNull()
                t.column("editedAt", .integer)
                t.column("revoked", .boolean).notNull().defaults(to: false)
                t.column("isForwarded", .boolean).notNull().defaults(to: false)
                t.column("typeName", .text)
                t.column("pushName", .text)
                t.column("extra", .jsonText)
                t.uniqueKey(["chatJid", "id"])
            }
            try db.create(index: "message_on_chat_sortKey", on: "message", columns: ["chatJid", "sortKey"])
            try db.create(index: "message_on_chat_timestamp", on: "message", columns: ["chatJid", "timestamp"])
            try db.create(index: "message_on_sender", on: "message", columns: ["senderJid"])

            try db.create(table: "media") { t in
                t.column("chatJid", .text).notNull()
                t.column("messageId", .text).notNull()
                t.primaryKey(["chatJid", "messageId"])
                t.foreignKey(["chatJid", "messageId"], references: "message", columns: ["chatJid", "id"],
                             onDelete: .cascade, onUpdate: .cascade)
                t.column("directPath", .text).notNull()
                t.column("mediaKey", .blob).notNull()
                t.column("fileSha256", .blob).notNull()
                t.column("fileEncSha256", .blob).notNull()
                t.column("fileLength", .integer).notNull()
                t.column("mediaType", .text).notNull()
                t.column("mimetype", .text)
                t.column("fileName", .text)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("durationSecs", .integer)
                t.column("jpegThumbnail", .blob)
                t.column("waveform", .blob)
                t.column("pageCount", .integer)
                t.column("isAnimated", .boolean)
                t.column("localPath", .text)
                t.column("downloadState", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "media_on_sha", on: "media", columns: ["fileSha256"])

            try db.create(table: "reaction") { t in
                t.column("chatJid", .text).notNull()
                t.column("messageId", .text).notNull()
                t.column("senderJid", .text).notNull()
                t.primaryKey(["chatJid", "messageId", "senderJid"])
                t.foreignKey(["chatJid", "messageId"], references: "message", columns: ["chatJid", "id"],
                             onDelete: .cascade, onUpdate: .cascade)
                t.column("emoji", .text).notNull()
                t.column("fromMe", .boolean).notNull()
                t.column("timestamp", .integer).notNull()
            }

            try db.create(table: "poll_vote") { t in
                t.column("chatJid", .text).notNull()
                t.column("messageId", .text).notNull()
                t.column("voterJid", .text).notNull()
                t.primaryKey(["chatJid", "messageId", "voterJid"])
                t.foreignKey(["chatJid", "messageId"], references: "message", columns: ["chatJid", "id"],
                             onDelete: .cascade, onUpdate: .cascade)
                t.column("selected", .jsonText).notNull()
                t.column("timestamp", .integer).notNull()
            }

            try db.create(table: "jid_alias") { t in
                t.primaryKey("lid", .text)
                t.column("pn", .text).notNull()
            }

            try db.create(table: "pending_mutation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chatJid", .text).notNull()
                t.column("messageId", .text).notNull()
                t.column("payload", .jsonText).notNull()
                t.column("createdAt", .integer).notNull()
            }
            try db.create(index: "pending_mutation_on_target", on: "pending_mutation", columns: ["chatJid", "messageId"])

            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("color", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "chat_tag") { t in
                t.column("chatJid", .text).notNull()
                    .references("chat", column: "jid", onDelete: .cascade, onUpdate: .cascade)
                t.column("tagId", .integer).notNull()
                    .references("tag", onDelete: .cascade)
                t.primaryKey(["chatJid", "tagId"])
            }
            try db.create(index: "chat_tag_on_tag", on: "chat_tag", columns: ["tagId"])

            // External-content FTS5 over message.text (body or caption), kept current by triggers.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE message_fts USING fts5(
                    text, content='message', content_rowid='localId',
                    tokenize='unicode61 remove_diacritics 2'
                );
                CREATE TRIGGER message_fts_ai AFTER INSERT ON message BEGIN
                    INSERT INTO message_fts(rowid, text) VALUES (new.localId, new.text);
                END;
                CREATE TRIGGER message_fts_ad AFTER DELETE ON message BEGIN
                    INSERT INTO message_fts(message_fts, rowid, text) VALUES ('delete', old.localId, old.text);
                END;
                CREATE TRIGGER message_fts_au AFTER UPDATE OF text ON message BEGIN
                    INSERT INTO message_fts(message_fts, rowid, text) VALUES ('delete', old.localId, old.text);
                    INSERT INTO message_fts(rowid, text) VALUES (new.localId, new.text);
                END;
                """)
        }

        // When unread/pin/mute/archive state was last set by a chat action or a read here; history
        // snapshots only apply that state while it is NULL.
        m.registerMigration("v2") { db in
            try db.alter(table: "chat") { t in t.add(column: "stateAt", .integer) }
        }

        // Quotes whose payload carried no text (the bridge could not describe it): describe the
        // stored original instead.
        m.registerMigration("v3") { db in
            try db.execute(sql: Self.fillQuoteFromTargetSQL)
        }

        // System messages used to store the stub's raw parameters; render them as sentences, then
        // refresh chat previews that show one.
        m.registerMigration("v4") { db in
            let aliases = Dictionary(try Row.fetchAll(db, sql: "SELECT lid, pn FROM jid_alias").map { ($0["lid"] as String, $0["pn"] as String) },
                                     uniquingKeysWith: { a, _ in a })
            let canon: (String) -> String = { aliases[$0] ?? $0 }
            let rows = try Row.fetchAll(db, sql: "SELECT localId, typeName, text, senderJid, fromMe FROM message WHERE kind = 'system' AND revoked = 0")
            for row in rows {
                let text = try IngestActor.renderSystem(db, typeName: row["typeName"], raw: row["text"], actor: row["senderJid"],
                                                        fromMe: row["fromMe"], canon: canon)
                try db.execute(sql: "UPDATE message SET text = ? WHERE localId = ?", arguments: [text, row["localId"] as Int64])
            }
            try db.execute(sql: """
                UPDATE chat SET lastMessageText = (SELECT text FROM message WHERE message.chatJid = chat.jid AND message.id = chat.lastMessageId)
                WHERE lastMessageKind = 'system'
                """)
        }

        // Deletions that must outlive their target: delete-for-me (kind 'message', no sender) and a
        // sender's reaction removal / vote clear (kind 'reaction' / 'vote', at `timestamp`). A later
        // or stale copy of the message, reaction or vote is not applied over them. No foreign key:
        // the target may never have been stored.
        m.registerMigration("v5") { db in
            try db.create(table: "tombstone", options: .withoutRowID) { t in
                t.column("chatJid", .text).notNull()
                t.column("messageId", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("senderJid", .text).notNull().defaults(to: "")
                t.column("timestamp", .integer).notNull()
                t.primaryKey(["chatJid", "messageId", "kind", "senderJid"])
            }
        }

        // Our own group messages were stored without a key participant, so reactions, edits and
        // revokes of them went out with an incomplete key. Fill them in (see
        // `backfillOwnGroupParticipants`); `participantInferred` marks a guessed value, which never
        // counts as evidence and is replaced once the server tells us the real one.
        m.registerMigration("v6") { db in
            try db.alter(table: "message") { t in t.add(column: "participantInferred", .boolean).notNull().defaults(to: false) }
            try Self.backfillOwnGroupParticipants(db)
        }

        return m
    }

    /// Fills (or re-guesses) the key participant of our own group messages that have none or only
    /// a guessed one (history copies of our messages carry none), in `groups` or everywhere. The
    /// value comes from, in order: the newest own message whose participant the server or a send
    /// reported (never a guessed one, so a wrong guess cannot reinforce itself); our JID in the
    /// namespace of the newest other sender (the group's current addressing); our phone-number JID.
    static func backfillOwnGroupParticipants(_ db: Database, groups only: [String]? = nil) throws {
        let own = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'ownPn'")
        let ownLid = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'ownLid'")
        guard own != nil || ownLid != nil else { return }
        let needsWork = "fromMe = 1 AND (participant IS NULL OR participantInferred = 1)"
        let groups = try only?.filter { $0.hasSuffix("@g.us") } ?? String.fetchAll(db, sql: """
            SELECT DISTINCT chatJid FROM message WHERE \(needsWork) AND chatJid LIKE '%@g.us'
            """)
        let bare = { (jid: String) in JID.user(jid) + "@" + (jid.split(separator: "@").last.map(String.init) ?? "") }
        for group in groups {
            if only != nil {
                let missing = try Bool.fetchOne(db, sql: "SELECT 1 FROM message WHERE chatJid = ? AND \(needsWork) LIMIT 1",
                                                arguments: [group]) ?? false
                guard missing else { continue }
            }
            var participant = try String.fetchOne(db, sql: """
                SELECT participant FROM message
                WHERE chatJid = ? AND fromMe = 1 AND participant IS NOT NULL AND participantInferred = 0
                ORDER BY sortKey DESC LIMIT 1
                """, arguments: [group])
            if participant == nil {
                let lidAddressed = try Bool.fetchOne(db, sql: """
                    SELECT participant LIKE '%@lid' FROM message
                    WHERE chatJid = ? AND fromMe = 0 AND participant IS NOT NULL ORDER BY sortKey DESC LIMIT 1
                    """, arguments: [group]) ?? false
                participant = (lidAddressed ? ownLid : own).map(bare)
            }
            guard let participant else { continue }
            try db.execute(sql: """
                UPDATE message SET participant = ?, participantInferred = 1
                WHERE chatJid = ? AND \(needsWork) AND IFNULL(participant, '') != ?
                """, arguments: [participant, group, participant])
        }
    }

    /// Fills an empty quote snippet (and kind) from the quoted message when it is stored locally.
    /// Callers append further `AND …` conditions.
    static let fillQuoteFromTargetSQL = """
        UPDATE message SET
          quotedKind = (SELECT t.kind FROM message t WHERE t.chatJid = message.chatJid AND t.id = message.quotedId),
          quotedSnippet = (SELECT t.text FROM message t WHERE t.chatJid = message.chatJid AND t.id = message.quotedId)
        WHERE quotedId IS NOT NULL AND IFNULL(quotedSnippet, '') = ''
          AND EXISTS (SELECT 1 FROM message t WHERE t.chatJid = message.chatJid AND t.id = message.quotedId)
        """
}
