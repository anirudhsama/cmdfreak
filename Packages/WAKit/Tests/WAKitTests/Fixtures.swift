import Foundation
import Synchronization
import Testing
@testable import WAKit

/// Synthetic bridge fixtures built from the generated UniFFI record types.
enum F {
    static let me = "15550000000@s.whatsapp.net"
    static let alicePN = "15551110000@s.whatsapp.net"
    static let aliceLID = "99887766@lid"
    static let bob = "15552220000@s.whatsapp.net"
    static let group = "120363000000000001@g.us"

    static func tempDB() throws -> AppDatabase {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wakit-tests-\(UUID().uuidString)")
        return try AppDatabase(url: dir.appending(path: "app.sqlite"))
    }

    static func message(
        _ id: String, chat: String, sender: String? = nil, fromMe: Bool = false, ts: Int64 = 1_700_000_000,
        kind: MessageKind = .text, text: String? = "hello", mentions: [String] = [], media: BridgeMedia? = nil, quoted: BridgeQuoted? = nil,
        reactions: [BridgeReaction] = [], pushName: String? = nil, verifiedName: String? = nil, status: MessageStatus? = nil,
        revoked: Bool = false, editedAt: Int64? = nil, poll: BridgePoll? = nil, location: BridgeLocation? = nil
    ) -> BridgeMessage {
        let sender = sender ?? (fromMe ? me : chat)
        return BridgeMessage(
            id: id, chatJid: chat, senderJid: sender, participant: chat.hasSuffix("@g.us") ? sender : nil,
            fromMe: fromMe, timestamp: ts, kind: kind, text: text, mentions: mentions, quoted: quoted, media: media,
            location: location, contact: nil, poll: poll, reactions: reactions, typeName: nil, pushName: pushName,
            verifiedName: verifiedName, status: status, isForwarded: false, revoked: revoked, editedAt: editedAt
        )
    }

    static func media(sha: UInt8 = 1, type: BridgeMediaType = .image, length: UInt64 = 1000, mimetype: String = "image/jpeg") -> BridgeMedia {
        BridgeMedia(
            directPath: "/v/t62/\(sha)", mediaKey: Data(repeating: 7, count: 32), fileSha256: Data(repeating: sha, count: 32),
            fileEncSha256: Data(repeating: sha &+ 1, count: 32), fileLength: length, mediaType: type, mimetype: mimetype,
            fileName: nil, width: 640, height: 480, durationSecs: nil, jpegThumbnail: Data([0xFF, 0xD8]),
            waveform: nil, pageCount: nil, isAnimated: nil
        )
    }

    static func key(_ id: String, chat: String, fromMe: Bool = false, participant: String? = nil) -> BridgeMessageKey {
        BridgeMessageKey(chatJid: chat, id: id, fromMe: fromMe, participant: participant)
    }

    static func live(_ messages: BridgeMessage..., updates: [BridgeMessageUpdate] = [], stanzas: [BridgeStanza] = []) -> BridgeEvent {
        .messages(messages: messages, updates: updates, stanzas: stanzas)
    }

    static func receipt(_ ids: [String], chat: String, kind: ReceiptKind, from: String? = nil) -> BridgeEvent {
        .receipt(receipt: BridgeReceipt(chatJid: chat, senderJid: from ?? chat, messageIds: ids, kind: kind, timestamp: 1_700_000_100))
    }

    static func chat(_ jid: String, name: String? = nil, lastActivity: Int64? = 1_700_000_000, unread: UInt32 = 0,
                     pinnedAt: Int64? = nil, archived: Bool = false, markedUnread: Bool = false) -> BridgeChat {
        BridgeChat(jid: jid, kind: ChatKind(jid: jid), name: name, lastActivityAt: lastActivity, unreadCount: unread,
                   markedUnread: markedUnread, pinnedAt: pinnedAt, mutedUntil: nil, archived: archived, readOnly: false)
    }

    static func history(
        chats: [BridgeChat] = [], messages: [BridgeMessage] = [], updates: [BridgeMessageUpdate] = [],
        contacts: [BridgeContact] = [], aliases: [BridgeJidAlias] = [], type: HistorySyncType = .recent,
        progress: UInt32? = nil, last: Bool = false
    ) -> BridgeEvent {
        .historyChunk(chunk: BridgeHistoryChunk(
            syncType: type, chunkOrder: 0, progress: progress, chats: chats, messages: messages, updates: updates,
            contacts: contacts, aliases: aliases, isLastInPayload: last))
    }
}

/// A client on `bridge`, and the sink the bridge would deliver to.
func makeClient(_ db: AppDatabase, _ bridge: FakeBridge) async throws -> (WAClient, any EventSink) {
    nonisolated(unsafe) var sink: (any EventSink)?
    let client = try await WAClient(database: db) { s in sink = s; return bridge }
    return (client, try #require(sink))
}

/// Calls the sink the way the bridge does: from a plain thread that may block.
@discardableResult
func deliver(_ sink: any EventSink, _ events: [BridgeEvent]) async -> Bool {
    await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        Thread.detachNewThread {
            c.resume(returning: sink.onEvents(events: events))
        }
    }
}

/// Polls `condition` for up to two seconds.
func waitFor(_ condition: () throws -> Bool) async throws {
    var tries = 0
    while try !condition(), tries < 200 {
        tries += 1
        try await Task.sleep(for: .milliseconds(10))
    }
}

extension AppDatabase {
    func chat(_ jid: String) throws -> ChatRecord? {
        try reader.read { try ChatRecord.fetchOne($0, key: jid) }
    }

    func message(_ chat: String, _ id: String) throws -> MessageRecord? {
        try reader.read { try MessageRecord.fetchOne($0, key: ["chatJid": chat, "id": id]) }
    }

    func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
        try reader.read { try Int.fetchOne($0, sql: sql, arguments: args) ?? 0 }
    }
}

/// In-memory `WaBridgeProtocol` for client/media tests. Records calls; never touches the network.
final class FakeBridge: WaBridgeProtocol, @unchecked Sendable {
    struct Calls {
        var markRead: [(String, [BridgeMessageKey])] = []
        var markChatRead: [(String, Bool)] = []
        var reactions: [(id: String, emoji: String)] = []
        var edits: [(id: String, text: String)] = []
        var revokes: [String] = []
        var pins: [(String, Bool)] = []
        var mutes: [(String, Int64?)] = []
        var archives: [(String, Bool)] = []
        var downloads = 0
        var overviews: [[String]] = []
        var sentTexts: [String] = []
        var textMentions: [[String]] = []
        var editMentions: [[String]] = []
        /// Every text send: the id it was asked to reuse and the quoted key.
        var textSends: [(messageId: String?, replyTo: BridgeMessageKey?)] = []
        var mediaSends: [(path: String, messageId: String?)] = []
        var nudges = 0
        var decryptParked: [[Data]] = []
        var profilePictures: [(jid: String, commonGid: String?)] = []
    }

    let calls = Mutex(Calls())
    var sendFails = false
    /// What `decryptParked` opens every envelope to (nil: nothing opens).
    var parkedResult: BridgeMessageUpdate?
    func decryptParked(envelopes: [Data]) async -> [BridgeMessageUpdate?] {
        calls.withLock { $0.decryptParked.append(envelopes) }
        return envelopes.map { _ in parkedResult }
    }
    var downloadDelay: Duration = .milliseconds(50)

    /// Reactions, edits, revokes and chat actions fail (after being recorded) while set.
    var actionsFail = false
    private func actionResult() throws {
        if actionsFail { throw BridgeError.Network("offline") }
    }

    func archiveChat(chat: String, archived: Bool) async throws {
        calls.withLock { $0.archives.append((chat, archived)) }
        try actionResult()
    }
    func cancelPairing() async throws {}
    func connect() async throws {}
    func dataDir() -> String { "/tmp" }
    func disconnect() async throws {}
    func downloadMedia(media: BridgeMedia, destPath: String, progress: (any ProgressSink)?) async throws {
        calls.withLock { $0.downloads += 1 }
        progress?.onProgress(done: 50, total: 100)
        try await Task.sleep(for: downloadDelay)
        try Data("payload".utf8).write(to: URL(filePath: destPath))
        progress?.onProgress(done: 100, total: 100)
    }
    func editMessage(target: BridgeMessageKey, text: String, mentions: [String]) async throws {
        calls.withLock { $0.edits.append((target.id, text)); $0.editMentions.append(mentions) }
        try actionResult()
    }
    var metadataJoinedAt: Int64?
    var communities: Set<String> = []
    func fetchGroupMetadata(jid: String) async throws -> BridgeGroup {
        BridgeGroup(jid: jid, subject: "Meta \(jid)", participantCount: 2, participants: [
            BridgeGroupParticipant(jid: F.alicePN, isAdmin: true, isSuperAdmin: false),
            BridgeGroupParticipant(jid: F.bob, isAdmin: false, isSuperAdmin: false),
        ], joinedAt: metadataJoinedAt, isCommunity: communities.contains(jid))
    }
    func checkBusiness(jids: [String]) async throws -> [BridgeBusinessCheck] { [] }
    var participating: [String] = []
    func listParticipatingGroups() async throws -> [String] { participating }
    var overviewsFail = false
    func fetchGroupOverviews(jids: [String]) async throws -> [BridgeGroup] {
        calls.withLock { $0.overviews.append(jids) }
        if overviewsFail { throw BridgeError.Network("offline") }
        return jids.map { BridgeGroup(jid: $0, subject: "Group \($0.prefix(4))", participantCount: 3, participants: []) }
    }
    func importCapture(captureDir: String) async throws {}
    func logout() async throws {}
    func markChatRead(chat: String, read: Bool) async throws {
        calls.withLock { $0.markChatRead.append((chat, read)) }
        try actionResult()
    }
    var markReadFails = false
    func markRead(chat: String, messages: [BridgeMessageKey]) async throws {
        calls.withLock { $0.markRead.append((chat, messages)) }
        if markReadFails { throw BridgeError.Network("offline") }
    }
    func muteChat(chat: String, until: Int64?) async throws {
        calls.withLock { $0.mutes.append((chat, until)) }
        try actionResult()
    }
    func nudgeReconnect() { calls.withLock { $0.nudges += 1 } }
    func pairWithPhone(number: String) async throws -> String { "ABCD-EFGH" }
    func pinChat(chat: String, pinned: Bool) async throws {
        calls.withLock { $0.pins.append((chat, pinned)) }
        try actionResult()
    }
    /// What `profilePicture` answers: a picture, none, or this error.
    var hasPicture = true
    var pictureError: BridgeError?
    func profilePicture(jid: String, commonGid: String?, preview: Bool, destPath: String) async throws -> Bool {
        calls.withLock { $0.profilePictures.append((jid, commonGid)) }
        if let pictureError { throw pictureError }
        guard hasPicture else { return false }
        try Data([0xFF, 0xD8]).write(to: URL(filePath: destPath))
        return true
    }
    func revokeMessage(target: BridgeMessageKey) async throws {
        calls.withLock { $0.revokes.append(target.id) }
        try actionResult()
    }
    func sendChatState(chat: String, state: ChatState) async throws {}
    func sendMedia(chat: String, media: BridgeOutgoingMedia, replyTo: BridgeMessageKey?, messageId: String?, progress: (any ProgressSink)?) async throws -> BridgeSendResult {
        calls.withLock { $0.mediaSends.append((media.filePath, messageId)) }
        throw BridgeError.NotImplemented("sendMedia")
    }
    func sendReaction(target: BridgeMessageKey, emoji: String) async throws {
        calls.withLock { $0.reactions.append((target.id, emoji)) }
        try actionResult()
    }
    func sendText(chat: String, text: String, mentions: [String], replyTo: BridgeMessageKey?, messageId: String?) async throws -> BridgeSendResult {
        calls.withLock {
            $0.sentTexts.append(text)
            $0.textMentions.append(mentions)
            $0.textSends.append((messageId, replyTo))
        }
        if sendFails { throw BridgeError.Network("offline") }
        let id = messageId ?? "SRV-\(text.hashValue.magnitude)"
        return BridgeSendResult(messageId: id, timestamp: 1_700_000_500,
                                message: F.message(id, chat: chat, fromMe: true, ts: 1_700_000_500, text: text))
    }
    func startPairingQr() async throws {}
    func stats() -> BridgeStats { BridgeStats(eventsReceived: 0, eventsDropped: 0, batchesFlushed: 0) }
    func subscribePresence(jid: String) async throws {}
}
