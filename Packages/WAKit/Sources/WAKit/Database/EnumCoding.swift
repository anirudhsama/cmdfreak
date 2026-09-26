import Foundation
import GRDB

/// Stores the generated UniFFI enums as stable strings (or ints for status) in SQLite and JSON.
protocol StableStringEnum: Codable, DatabaseValueConvertible, CaseIterable {
    var stableName: String { get }
}

extension StableStringEnum {
    init?(stableName: String) {
        guard let v = Self.allCases.first(where: { $0.stableName == stableName }) else { return nil }
        self = v
    }

    public var databaseValue: DatabaseValue { stableName.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
        String.fromDatabaseValue(dbValue).flatMap(Self.init(stableName:))
    }

    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = Self(stableName: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown \(Self.self) \(s)"))
        }
        self = v
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(stableName)
    }
}

extension ChatKind: @retroactive CaseIterable, @retroactive Codable, @retroactive DatabaseValueConvertible, StableStringEnum {
    public static let allCases: [ChatKind] = [.dm, .group, .broadcast, .status, .newsletter]
    var stableName: String {
        switch self {
        case .dm: "dm"
        case .group: "group"
        case .broadcast: "broadcast"
        case .status: "status"
        case .newsletter: "newsletter"
        }
    }

    /// Kind inferred from the JID server part.
    public init(jid: String) {
        if jid == "status@broadcast" { self = .status }
        else if jid.hasSuffix("@g.us") { self = .group }
        else if jid.hasSuffix("@broadcast") { self = .broadcast }
        else if jid.hasSuffix("@newsletter") { self = .newsletter }
        else { self = .dm }
    }
}

extension MessageKind: @retroactive CaseIterable, @retroactive Codable, @retroactive DatabaseValueConvertible, StableStringEnum {
    public static let allCases: [MessageKind] = [
        .text, .image, .video, .gif, .sticker, .document, .audio, .voice,
        .location, .contact, .poll, .system, .undecryptable, .unsupported,
    ]
    var stableName: String {
        switch self {
        case .text: "text"
        case .image: "image"
        case .video: "video"
        case .gif: "gif"
        case .sticker: "sticker"
        case .document: "document"
        case .audio: "audio"
        case .voice: "voice"
        case .location: "location"
        case .contact: "contact"
        case .poll: "poll"
        case .system: "system"
        case .undecryptable: "undecryptable"
        case .unsupported: "unsupported"
        }
    }
}

extension BridgeMediaType: @retroactive CaseIterable, @retroactive Codable, @retroactive DatabaseValueConvertible, StableStringEnum {
    public static let allCases: [BridgeMediaType] = [.image, .video, .audio, .document, .sticker]
    var stableName: String {
        switch self {
        case .image: "image"
        case .video: "video"
        case .audio: "audio"
        case .document: "document"
        case .sticker: "sticker"
        }
    }
}

/// Stored as an ordered rank so "status only moves forward" is a `<` comparison.
/// `played` is collapsed to `read` on write.
extension MessageStatus: @retroactive Codable, @retroactive DatabaseValueConvertible {
    public var rank: Int {
        switch self {
        case .failed: -1
        case .pending: 0
        case .sent: 1
        case .delivered: 2
        case .read, .played: 3
        }
    }

    public init(rank: Int) {
        switch rank {
        case ..<0: self = .failed
        case 0: self = .pending
        case 1: self = .sent
        case 2: self = .delivered
        default: self = .read
        }
    }

    public var databaseValue: DatabaseValue { rank.databaseValue }
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> MessageStatus? {
        Int.fromDatabaseValue(dbValue).map(MessageStatus.init(rank:))
    }
    public init(from decoder: any Decoder) throws {
        self.init(rank: try decoder.singleValueContainer().decode(Int.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rank)
    }
}
