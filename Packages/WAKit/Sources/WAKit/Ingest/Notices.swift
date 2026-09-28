import Foundation

/// A live incoming message that should raise a system notification, resolved for display at commit.
public struct IncomingNotice: Sendable, Hashable {
    public var chatJid: String
    public var messageId: String
    public var chatTitle: String
    /// Group chats only: who sent it.
    public var senderName: String?
    public var kind: MessageKind
    public var text: String?
    public var timestamp: Int64
    /// The chat's cached avatar file, when it has been fetched.
    public var avatarURL: URL?
}

/// What the notification layer reacts to, published by `IngestActor` after each commit.
public enum NoticeEvent: Sendable, Hashable {
    case incoming(IncomingNotice)
    /// Read here or on another device, cleared or deleted: its delivered notifications are stale.
    case chatRead(String)
    /// Deleted for everyone or for me.
    case messageRemoved(chatJid: String, messageId: String)
}
