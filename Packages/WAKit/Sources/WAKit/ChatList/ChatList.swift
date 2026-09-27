import Foundation
import GRDB
import os

/// Which chats a chat-list shows. Rail items produce these; tags can include or exclude chats.
public struct ChatFilter: Hashable, Sendable {
    /// `nil` shows both archived and non-archived chats.
    public var archived: Bool?
    public var kinds: Set<ChatKind>
    /// Non-empty: the chat must carry at least one of these tags.
    public var includeTags: Set<Int64>
    /// The chat must carry none of these tags.
    public var excludeTags: Set<Int64>
    public var unreadOnly: Bool

    public init(
        archived: Bool? = false,
        kinds: Set<ChatKind> = [.dm, .group, .broadcast],
        includeTags: Set<Int64> = [],
        excludeTags: Set<Int64> = [],
        unreadOnly: Bool = false
    ) {
        self.archived = archived
        self.kinds = kinds
        self.includeTags = includeTags
        self.excludeTags = excludeTags
        self.unreadOnly = unreadOnly
    }

    public static let chats = ChatFilter(archived: false)
    public static let archived = ChatFilter(archived: true)
}

/// An entry in the sidebar's source list. Tags arrive later as more items.
public enum RailItem: Hashable, Sendable {
    case chats
    case unread
    case groups
    case archived
    case tag(id: Int64, name: String)

    /// `hiddenTags` are tags whose chats should not appear under `Chats`.
    public func filter(hiddenTags: Set<Int64> = []) -> ChatFilter {
        switch self {
        case .chats: ChatFilter(archived: false, excludeTags: hiddenTags)
        case .unread: ChatFilter(archived: false, unreadOnly: true)
        case .groups: ChatFilter(archived: false, kinds: [.group])
        case .archived: ChatFilter(archived: true)
        case .tag(let id, _): ChatFilter(archived: nil, includeTags: [id])
        }
    }
}

/// Unread-chat counts for the sidebar badges.
public struct SidebarCounts: Hashable, Sendable {
    public var chats = 0
    public var groups = 0
    public var archived = 0
    public init() {}

    static func fetch(_ db: Database) throws -> SidebarCounts {
        let row = try Row.fetchOne(db, sql: """
            SELECT
              COUNT(*) FILTER (WHERE archived = 0),
              COUNT(*) FILTER (WHERE archived = 0 AND kind = 'group'),
              COUNT(*) FILTER (WHERE archived = 1)
            FROM chat
            WHERE (unreadCount > 0 OR markedUnread)
              AND (lastActivityAt IS NOT NULL OR pinnedAt IS NOT NULL)
              AND kind IN ('dm', 'group', 'broadcast')
            """)
        var counts = SidebarCounts()
        if let row {
            counts.chats = row[0]
            counts.groups = row[1]
            counts.archived = row[2]
        }
        return counts
    }
}

/// Inputs for the chat-list row's last-message line.
public struct ChatPreview: Hashable, Sendable {
    public var messageId: String
    public var kind: MessageKind
    public var text: String?
    public var fromMe: Bool
    public var senderJid: String?
    /// Group chats only: who sent it (not set when `fromMe`).
    public var senderName: String?
    public var status: MessageStatus?
    public var revoked: Bool
}

public struct ChatListItem: Hashable, Sendable, Identifiable {
    public var chat: ChatRecord
    /// The DM counterpart's contact row, when known.
    public var contact: ContactRecord?
    public var title: String
    public var preview: ChatPreview?

    public var id: String { chat.jid }
    public var unreadCount: Int { chat.unreadCount }
    public var showsUnread: Bool { chat.unreadCount > 0 || chat.markedUnread }
}

public enum ChatListQuery {
    public static func fetch(_ db: Database, filter: ChatFilter) throws -> [ChatListItem] {
        var clauses = ["(lastActivityAt IS NOT NULL OR pinnedAt IS NOT NULL)"]
        var args: [any DatabaseValueConvertible] = []
        if let archived = filter.archived {
            clauses.append("archived = ?")
            args.append(archived)
        }
        if !filter.kinds.isEmpty {
            clauses.append("kind IN (\(placeholders(filter.kinds.count)))")
            args.append(contentsOf: filter.kinds.map(\.stableName) as [any DatabaseValueConvertible])
        }
        if !filter.includeTags.isEmpty {
            clauses.append("jid IN (SELECT chatJid FROM chat_tag WHERE tagId IN (\(placeholders(filter.includeTags.count))))")
            args.append(contentsOf: filter.includeTags.map { $0 as any DatabaseValueConvertible })
        }
        if !filter.excludeTags.isEmpty {
            clauses.append("jid NOT IN (SELECT chatJid FROM chat_tag WHERE tagId IN (\(placeholders(filter.excludeTags.count))))")
            args.append(contentsOf: filter.excludeTags.map { $0 as any DatabaseValueConvertible })
        }
        if filter.unreadOnly {
            clauses.append("(unreadCount > 0 OR markedUnread)")
        }
        let sql = """
            SELECT * FROM chat WHERE \(clauses.joined(separator: " AND "))
            ORDER BY pinnedAt IS NULL, pinnedAt DESC, lastActivityAt DESC, jid
            """
        let chats = try ChatRecord.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        let own = try ownJid(db)

        var contactJids = Set<String>()
        for chat in chats {
            if chat.kind == .dm { contactJids.insert(chat.jid) }
            if chat.kind == .group, chat.lastMessageFromMe == false, let s = chat.lastMessageSenderJid { contactJids.insert(s) }
        }
        let contacts = try ContactRecord.fetchAll(db, keys: Array(contactJids))
        let byJid = Dictionary(contacts.map { ($0.jid, $0) }, uniquingKeysWith: { a, _ in a })

        return chats.map { chat in
            let contact = chat.kind == .dm ? byJid[chat.jid] : nil
            var preview: ChatPreview?
            if let mid = chat.lastMessageId, let kind = chat.lastMessageKind {
                let fromMe = chat.lastMessageFromMe ?? false
                var senderName: String?
                if chat.kind == .group, !fromMe, let s = chat.lastMessageSenderJid {
                    senderName = byJid[s]?.displayName ?? JID.phoneDisplay(s)
                }
                preview = ChatPreview(
                    messageId: mid, kind: kind, text: chat.lastMessageText, fromMe: fromMe,
                    senderJid: chat.lastMessageSenderJid, senderName: senderName,
                    status: chat.lastMessageStatus, revoked: chat.lastMessageRevoked ?? false
                )
            }
            return ChatListItem(chat: chat, contact: contact, title: title(chat, contact, ownJid: own), preview: preview)
        }
    }

    public static func title(_ chat: ChatRecord, _ contact: ContactRecord?, ownJid: String? = nil) -> String {
        if chat.kind == .dm, chat.jid == ownJid {
            return "\(contact?.displayName.flatMap(unmasked) ?? "Me") (You)"
        }
        // DMs: the address-book/push name beats the conversation name, which history sync sometimes
        // fills with a masked number ("+91∙∙∙∙∙∙∙∙02").
        if chat.kind == .dm, let name = contact?.displayName.flatMap(unmasked) { return name }
        if let name = chat.name.nonEmpty.flatMap(unmasked) { return name }
        if let name = contact?.displayName.flatMap(unmasked) { return name }
        switch chat.kind {
        case .group: return "Group"
        case .broadcast: return "Broadcast list"
        default: return JID.phoneDisplay(chat.jid) ?? chat.jid
        }
    }

    /// WhatsApp masks hidden phone numbers with bullets; such a "name" is worse than the real number.
    static func unmasked(_ name: String) -> String? {
        name.contains(where: { $0 == "∙" || $0 == "•" || $0 == "●" }) ? nil : name
    }

    static func ownJid(_ db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'ownPn'")
    }

    public static func observation(filter: ChatFilter) -> ValueObservation<ValueReducers.Fetch<[ChatListItem]>> {
        ValueObservation.trackingConstantRegion { db in try fetch(db, filter: filter) }
    }
}

extension AppDatabase {
    /// Observes the chat list. The first value is delivered synchronously (`.immediate`), so it is
    /// available for the first frame; later values arrive on the main actor without an extra hop.
    @MainActor
    public func observeChatList(
        filter: ChatFilter,
        onError: @escaping @MainActor (any Error) -> Void = { WAKit.log.error("chat list observation: \($0)") },
        onChange: @escaping @MainActor ([ChatListItem]) -> Void
    ) -> AnyDatabaseCancellable {
        ChatListQuery.observation(filter: filter).start(
            in: pool,
            scheduling: .immediate,
            onError: { error in MainActor.assumeIsolated { onError(error) } },
            onChange: { items in MainActor.assumeIsolated { onChange(items) } }
        )
    }
}

extension AppDatabase {
    /// Observes the sidebar's unread-chat counts; the first value is delivered synchronously.
    @MainActor
    public func observeSidebarCounts(onChange: @escaping @MainActor (SidebarCounts) -> Void) -> AnyDatabaseCancellable {
        ValueObservation.trackingConstantRegion(SidebarCounts.fetch).removeDuplicates().start(
            in: pool,
            scheduling: .immediate,
            onError: { error in WAKit.log.error("sidebar counts observation: \(error)") },
            onChange: { counts in MainActor.assumeIsolated { onChange(counts) } }
        )
    }
}

func placeholders(_ n: Int) -> String {
    Array(repeating: "?", count: n).joined(separator: ",")
}

public enum JID {
    public static func user(_ jid: String) -> String {
        let local = jid.split(separator: "@", maxSplits: 1).first.map(String.init) ?? jid
        return local.split(separator: ":", maxSplits: 1).first.map(String.init) ?? local
    }

    public static func isPhoneNumber(_ jid: String) -> Bool { jid.hasSuffix("@s.whatsapp.net") }
    public static func isLid(_ jid: String) -> Bool { jid.hasSuffix("@lid") }

    /// "+15551234567" for phone-number JIDs; nil otherwise.
    public static func phoneDisplay(_ jid: String) -> String? {
        isPhoneNumber(jid) ? "+" + user(jid) : nil
    }
}
