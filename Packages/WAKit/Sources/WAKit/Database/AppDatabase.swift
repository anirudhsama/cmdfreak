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
        URL.applicationSupportDirectory.appending(path: "BetterWA/app.sqlite")
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

        return m
    }
}
