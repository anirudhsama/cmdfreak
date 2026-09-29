import Foundation
import GRDB

/// A message row with everything the chat view renders: media, reactions, poll votes, sender name.
public struct MessageItem: Hashable, Sendable, Identifiable {
    public var message: MessageRecord
    public var media: MediaRecord?
    public var reactions: [ReactionRecord]
    public var pollVotes: [PollVoteRecord]
    /// Group chats: the sender's display name (nil for own messages).
    public var senderName: String?
    /// Names for the users mentioned in the text and quote, keyed by user number (see `Mentions`).
    public var mentionNames: [String: String]

    public init(message: MessageRecord, media: MediaRecord? = nil, reactions: [ReactionRecord] = [], pollVotes: [PollVoteRecord] = [],
                senderName: String? = nil, mentionNames: [String: String] = [:]) {
        self.message = message
        self.media = media
        self.reactions = reactions
        self.pollVotes = pollVotes
        self.senderName = senderName
        self.mentionNames = mentionNames
    }

    /// The text with mentions shown by name. `message.text` keeps the wire form.
    public var displayText: String? { message.text.map { Mentions.apply($0, mentionNames) } }
    public var displayQuotedSnippet: String? { message.quotedSnippet.map { Mentions.apply($0, mentionNames) } }

    public var id: String { message.id }
    public var sortKey: Int64 { message.sortKey }
}

enum MessageItemFetcher {
    static func items(_ db: Database, chatJid: String, ids: [String]) throws -> [MessageItem] {
        guard !ids.isEmpty else { return [] }
        let messages = try MessageRecord.fetchAll(
            db,
            sql: "SELECT * FROM message WHERE chatJid = ? AND id IN (\(placeholders(ids.count))) ORDER BY sortKey",
            arguments: StatementArguments([chatJid] + ids)
        )
        return try hydrate(db, chatJid: chatJid, messages: messages)
    }

    static func hydrate(_ db: Database, chatJid: String, messages: [MessageRecord]) throws -> [MessageItem] {
        guard !messages.isEmpty else { return [] }
        let ids = messages.map(\.id)
        let idArgs = StatementArguments([chatJid] + ids)
        let inClause = "chatJid = ? AND messageId IN (\(placeholders(ids.count)))"

        var media: [String: MediaRecord] = [:]
        if messages.contains(where: { $0.kind.hasMedia }) {
            for m in try MediaRecord.fetchAll(db, sql: "SELECT * FROM media WHERE \(inClause)", arguments: idArgs) {
                media[m.messageId] = m
            }
        }
        var reactions: [String: [ReactionRecord]] = [:]
        for r in try ReactionRecord.fetchAll(db, sql: "SELECT * FROM reaction WHERE \(inClause) ORDER BY timestamp", arguments: idArgs) {
            reactions[r.messageId, default: []].append(r)
        }
        var votes: [String: [PollVoteRecord]] = [:]
        if messages.contains(where: { $0.kind == .poll }) {
            for v in try PollVoteRecord.fetchAll(db, sql: "SELECT * FROM poll_vote WHERE \(inClause)", arguments: idArgs) {
                votes[v.messageId, default: []].append(v)
            }
        }
        var names: [String: String] = [:]
        if ChatKind(jid: chatJid) == .group {
            let senders = Set(messages.filter { !$0.fromMe }.map(\.senderJid))
            for c in try ContactRecord.fetchAll(db, keys: Array(senders)) {
                if let n = c.displayName { names[c.jid] = n }
            }
        }

        let mentions = try Mentions.names(db, in: messages.flatMap { [$0.text, $0.quotedSnippet] })

        return messages.map { m in
            MessageItem(
                message: m,
                media: media[m.id],
                reactions: reactions[m.id] ?? [],
                pollVotes: votes[m.id] ?? [],
                senderName: m.fromMe ? nil : (names[m.senderJid] ?? m.pushName.nonEmpty ?? JID.phoneDisplay(m.senderJid)),
                mentionNames: mentions
            )
        }
    }
}

extension MessageKind {
    public var hasMedia: Bool {
        switch self {
        case .image, .video, .gif, .sticker, .document, .audio, .voice: true
        default: false
        }
    }
}
