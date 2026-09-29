import Foundation
import GRDB

public struct ChatRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "chat"

    public var jid: String
    public var kind: ChatKind
    public var name: String?
    public var lastActivityAt: Int64?
    public var unreadCount: Int
    public var markedUnread: Bool
    public var pinnedAt: Int64?
    public var mutedUntil: Int64?
    public var archived: Bool
    public var readOnly: Bool
    public var participantCount: Int?
    /// A profile picture is cached at `AvatarService.fileURL(for: jid)`.
    public var hasAvatar: Bool
    public var avatarCheckedAt: Int64?
    public var lastMessageId: String?
    public var lastMessageKind: MessageKind?
    public var lastMessageText: String?
    public var lastMessageFromMe: Bool?
    public var lastMessageSenderJid: String?
    public var lastMessageStatus: MessageStatus?
    public var lastMessageRevoked: Bool?

    public var id: String { jid }

    public init(jid: String, kind: ChatKind? = nil) {
        self.jid = jid
        self.kind = kind ?? ChatKind(jid: jid)
        unreadCount = 0
        markedUnread = false
        archived = false
        readOnly = false
        hasAvatar = false
    }

    public var isPinned: Bool { pinnedAt != nil }
    public var avatarURL: URL? { hasAvatar ? AvatarService.fileURL(for: jid) : nil }

    public func isMuted(now: Int64 = Int64(Date().timeIntervalSince1970)) -> Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > now
    }
}

public struct ContactRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "contact"

    public var jid: String
    public var fullName: String?
    public var firstName: String?
    public var pushName: String?
    public var phone: String?
    /// A WhatsApp Business account, as of `businessCheckedAt` (nil: never checked).
    public var isBusiness: Bool
    public var businessCheckedAt: Int64?

    public var id: String { jid }

    public init(jid: String, fullName: String? = nil, firstName: String? = nil, pushName: String? = nil, phone: String? = nil) {
        self.jid = jid
        self.fullName = fullName
        self.firstName = firstName
        self.pushName = pushName
        self.phone = phone
        isBusiness = false
    }

    /// Saved name first, then the sender's push name, then the phone number.
    public var displayName: String? {
        fullName.nonEmpty ?? firstName.nonEmpty ?? pushName.nonEmpty ?? phone.nonEmpty.map { "+" + $0 }
    }
}

public struct GroupParticipantRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "group_participant"
    public var groupJid: String
    public var jid: String
    public var isAdmin: Bool
    public var isSuperAdmin: Bool
}

public struct LocationInfo: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var name: String?
    public var address: String?
    public var isLive: Bool
}

public struct ContactCardInfo: Codable, Hashable, Sendable {
    public var displayName: String
    public var vcard: String
}

public struct PollInfo: Codable, Hashable, Sendable {
    public var question: String
    public var options: [String]
    public var selectableCount: Int
}

/// Kind-specific payload stored as JSON in `message.extra`.
public struct MessageExtra: Codable, Hashable, Sendable {
    public var location: LocationInfo?
    public var contact: ContactCardInfo?
    public var poll: PollInfo?

    var isEmpty: Bool { location == nil && contact == nil && poll == nil }
}

public struct MessageRecord: Codable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "message"

    public var localId: Int64?
    public var chatJid: String
    public var id: String
    public var senderJid: String
    public var participant: String?
    public var fromMe: Bool
    public var timestamp: Int64
    public var sortKey: Int64
    public var kind: MessageKind
    public var text: String?
    public var quotedId: String?
    public var quotedSenderJid: String?
    public var quotedKind: MessageKind?
    public var quotedSnippet: String?
    public var status: MessageStatus
    public var editedAt: Int64?
    public var revoked: Bool
    public var isForwarded: Bool
    public var typeName: String?
    public var pushName: String?
    public var extra: MessageExtra?

    public init(
        localId: Int64? = nil, chatJid: String, id: String, senderJid: String, participant: String? = nil, fromMe: Bool,
        timestamp: Int64, sortKey: Int64, kind: MessageKind, text: String?, quotedId: String? = nil, quotedSenderJid: String? = nil,
        quotedKind: MessageKind? = nil, quotedSnippet: String? = nil, status: MessageStatus, editedAt: Int64? = nil, revoked: Bool = false,
        isForwarded: Bool = false, typeName: String? = nil, pushName: String? = nil, extra: MessageExtra? = nil
    ) {
        self.localId = localId
        self.chatJid = chatJid
        self.id = id
        self.senderJid = senderJid
        self.participant = participant
        self.fromMe = fromMe
        self.timestamp = timestamp
        self.sortKey = sortKey
        self.kind = kind
        self.text = text
        self.quotedId = quotedId
        self.quotedSenderJid = quotedSenderJid
        self.quotedKind = quotedKind
        self.quotedSnippet = quotedSnippet
        self.status = status
        self.editedAt = editedAt
        self.revoked = revoked
        self.isForwarded = isForwarded
        self.typeName = typeName
        self.pushName = pushName
        self.extra = extra
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        localId = inserted.rowID
    }

    /// Key for reactions, edits, revokes, quotes and receipts.
    public var key: BridgeMessageKey {
        BridgeMessageKey(chatJid: chatJid, id: id, fromMe: fromMe, participant: participant)
    }

    public var isPending: Bool { status == .pending }
}

public enum MediaDownloadState: Int, Codable, Hashable, Sendable, DatabaseValueConvertible {
    case none = 0
    case downloading = 1
    case downloaded = 2
    case failed = 3
}

public struct MediaRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "media"

    public var chatJid: String
    public var messageId: String
    public var directPath: String
    public var mediaKey: Data
    public var fileSha256: Data
    public var fileEncSha256: Data
    public var fileLength: Int64
    public var mediaType: BridgeMediaType
    public var mimetype: String?
    public var fileName: String?
    public var width: Int?
    public var height: Int?
    public var durationSecs: Int?
    public var jpegThumbnail: Data?
    public var waveform: Data?
    public var pageCount: Int?
    public var isAnimated: Bool?
    /// The user's original file for an outgoing attachment that has no `fileSha256` yet. Every
    /// other file is located by `MediaStore` from the hash.
    public var sourcePath: String?
    public var downloadState: MediaDownloadState

    /// The download parameters in bridge form.
    public var bridgeMedia: BridgeMedia {
        BridgeMedia(
            directPath: directPath, mediaKey: mediaKey, fileSha256: fileSha256, fileEncSha256: fileEncSha256,
            fileLength: UInt64(max(0, fileLength)), mediaType: mediaType, mimetype: mimetype, fileName: fileName,
            width: width.map(UInt32.init), height: height.map(UInt32.init), durationSecs: durationSecs.map(UInt32.init),
            jpegThumbnail: jpegThumbnail, waveform: waveform, pageCount: pageCount.map(UInt32.init), isAnimated: isAnimated
        )
    }
}

public struct ReactionRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "reaction"
    public var chatJid: String
    public var messageId: String
    public var senderJid: String
    public var emoji: String
    public var fromMe: Bool
    public var timestamp: Int64

    public init(chatJid: String, messageId: String, senderJid: String, emoji: String, fromMe: Bool, timestamp: Int64) {
        self.chatJid = chatJid
        self.messageId = messageId
        self.senderJid = senderJid
        self.emoji = emoji
        self.fromMe = fromMe
        self.timestamp = timestamp
    }
}

public struct PollVoteRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "poll_vote"
    public var chatJid: String
    public var messageId: String
    public var voterJid: String
    public var selected: [String]
    public var timestamp: Int64
}

public struct JidAliasRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "jid_alias"
    public var lid: String
    public var pn: String
}

public struct TagRecord: Codable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "tag"
    public var id: Int64?
    public var name: String
    public var color: String?
    public var sortOrder: Int

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct ChatTagRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chat_tag"
    public var chatJid: String
    public var tagId: Int64
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let s = self, !s.isEmpty else { return nil }
        return s
    }
}
