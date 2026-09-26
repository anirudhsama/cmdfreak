import Foundation
import GRDB

public struct MessagePage: Hashable, Sendable {
    /// Ascending by `sortKey`.
    public var items: [MessageItem]
    public var hasOlder: Bool
    public var hasNewer: Bool

    public var oldestSortKey: Int64? { items.first?.sortKey }
    public var newestSortKey: Int64? { items.last?.sortKey }
}

/// Pages one chat's messages by `sortKey`. Pages are ascending; cursors are exclusive.
public struct ChatWindowLoader: Sendable {
    public let chatJid: String
    let reader: any DatabaseReader

    public init(database: AppDatabase, chatJid: String) {
        self.chatJid = chatJid
        self.reader = database.reader
    }

    /// The newest `limit` messages.
    public func initial(limit: Int = 60) async throws -> MessagePage {
        try await reader.read { db in try initial(db, limit: limit) }
    }

    /// Synchronous variant for preloaders that already run off the main thread.
    public func initialSync(limit: Int = 60) throws -> MessagePage {
        try reader.read { db in try initial(db, limit: limit) }
    }

    public func older(before sortKey: Int64, limit: Int = 60) async throws -> MessagePage {
        try await reader.read { db in
            let rows = try fetch(db, where: "sortKey < ?", [sortKey], order: "DESC", limit: limit + 1)
            let more = rows.count > limit
            return MessagePage(items: try hydrate(db, Array(rows.prefix(limit)).reversed()), hasOlder: more, hasNewer: true)
        }
    }

    public func newer(after sortKey: Int64, limit: Int = 60) async throws -> MessagePage {
        try await reader.read { db in
            let rows = try fetch(db, where: "sortKey > ?", [sortKey], order: "ASC", limit: limit + 1)
            let more = rows.count > limit
            return MessagePage(items: try hydrate(db, Array(rows.prefix(limit))), hasOlder: true, hasNewer: more)
        }
    }

    /// A page centred on `messageId` (inclusive). Nil when the message is not stored.
    public func around(messageId: String, limit: Int = 60) async throws -> MessagePage? {
        try await reader.read { db in
            guard let key = try Int64.fetchOne(
                db, sql: "SELECT sortKey FROM message WHERE chatJid = ? AND id = ?", arguments: [chatJid, messageId]
            ) else { return nil }
            let half = max(1, limit / 2)
            let before = try fetch(db, where: "sortKey < ?", [key], order: "DESC", limit: half + 1)
            let after = try fetch(db, where: "sortKey >= ?", [key], order: "ASC", limit: half + 1)
            let rows = Array(before.prefix(half).reversed()) + Array(after.prefix(half))
            return MessagePage(items: try hydrate(db, rows), hasOlder: before.count > half, hasNewer: after.count > half)
        }
    }

    public func items(ids: [String]) async throws -> [MessageItem] {
        try await reader.read { db in try MessageItemFetcher.items(db, chatJid: chatJid, ids: ids) }
    }

    private func initial(_ db: Database, limit: Int) throws -> MessagePage {
        let rows = try fetch(db, where: nil, [], order: "DESC", limit: limit + 1)
        return MessagePage(items: try hydrate(db, Array(rows.prefix(limit)).reversed()), hasOlder: rows.count > limit, hasNewer: false)
    }

    private func fetch(_ db: Database, where cond: String?, _ args: [Int64], order: String, limit: Int) throws -> [MessageRecord] {
        let extra = cond.map { " AND \($0)" } ?? ""
        return try MessageRecord.fetchAll(
            db,
            sql: "SELECT * FROM message WHERE chatJid = ?\(extra) ORDER BY sortKey \(order) LIMIT ?",
            arguments: StatementArguments([chatJid as any DatabaseValueConvertible] + args + [limit])
        )
    }

    private func hydrate(_ db: Database, _ rows: some Sequence<MessageRecord>) throws -> [MessageItem] {
        try MessageItemFetcher.hydrate(db, chatJid: chatJid, messages: Array(rows))
    }
}
