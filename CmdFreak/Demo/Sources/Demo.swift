import CryptoKit
import Foundation
import WAKit

/// The demo build: made-up chats from a bundled database (see Tools/demo-gen), opened through the
/// normal client with a bridge that never touches the network.
enum Demo {
    static let resources = Bundle.main.resourceURL!.appending(path: "Demo", directoryHint: .isDirectory)

    /// Every launch starts from the bundled state: the database is copied over the previous run's,
    /// cached media and avatars are dropped, and all timestamps move to the present.
    @MainActor
    static func makeClient() throws -> WAClient {
        // The folders below are wiped; never let that be a real account's.
        precondition(WAKit.storageName != WAKit.appName, "the demo needs its own CmdFreakStorageName")
        let fm = FileManager.default
        try? fm.removeItem(at: WAKit.dataDirectory)
        try? fm.removeItem(at: WAKit.cacheDirectory)
        try fm.createDirectory(at: WAKit.dataDirectory, withIntermediateDirectories: true)
        let url = WAKit.dataDirectory.appending(path: "app.sqlite")
        try fm.copyItem(at: resources.appending(path: "demo.sqlite"), to: url)
        let database = try AppDatabase(url: url)
        try shiftTimestamps(database)
        let bridge = try DemoBridge(database: database)
        return try WAClient(database: database) { sink in
            bridge.sink = sink
            return bridge
        }
    }

    /// Moves every stored point in time (a migration that adds a timestamp column must add it here)
    /// by whole days, then from GMT to this Mac's zone using the offset in effect at that moment. The
    /// generator writes times as GMT, so each message keeps its time of day on this Mac's clock, across
    /// DST changes too; the newest lands on the latest day where it is not in the future.
    private static func shiftTimestamps(_ database: AppDatabase) throws {
        try database.pool.write { db in
            guard let newest = try Int64.fetchOne(db, sql: "SELECT MAX(timestamp) FROM message") else { return }
            let latest = Int64(Date().timeIntervalSince1970) - 4 * 60
            let offsetNow = Int64(TimeZone.current.secondsFromGMT())
            let days = Int64((Double(latest - (newest - offsetNow)) / 86_400).rounded(.down))
            db.add(function: DatabaseFunction("demo_shift", argumentCount: 1, pure: true) { values in
                guard let t = Int64.fromDatabaseValue(values[0]) else { return nil }
                let wall = t + days * 86_400
                return wall - Int64(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(wall))))
            })
            for sql in [
                """
                UPDATE message SET sortKey = sortKey + ((demo_shift(timestamp) - timestamp) << \(SortKey.seqBits)),
                    timestamp = demo_shift(timestamp), editedAt = demo_shift(editedAt)
                """,
                "UPDATE reaction SET timestamp = demo_shift(timestamp)",
                "UPDATE poll_vote SET timestamp = demo_shift(timestamp)",
                """
                UPDATE chat SET lastActivityAt = demo_shift(lastActivityAt), pinnedAt = demo_shift(pinnedAt),
                    stateAt = demo_shift(stateAt)
                """,
                "UPDATE contact SET businessCheckedAt = demo_shift(businessCheckedAt)",
            ] {
                try db.execute(sql: sql)
            }
        }
    }
}

/// Behaves like a connected account: sends succeed and are delivered and read a moment later,
/// media and avatars come from the bundle, and everything else is accepted and dropped.
final class DemoBridge: WaBridgeProtocol, @unchecked Sendable {
    /// Set once, before the client makes its first call.
    var sink: (any EventSink)?
    private let database: AppDatabase
    private let ownJid: String

    init(database: AppDatabase) throws {
        self.database = database
        ownJid = try database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'ownPn'")
        } ?? ""
    }

    func connect() async throws { deliver([.connection(state: .connected)]) }

    // MARK: Sending

    func sendText(chat: String, text: String, replyTo: BridgeMessageKey?, messageId: String?) async throws -> BridgeSendResult {
        try await Task.sleep(for: .milliseconds(300))
        return sent(chat: chat, kind: .text, text: text, media: nil)
    }

    func sendMedia(chat: String, media: BridgeOutgoingMedia, replyTo: BridgeMessageKey?, messageId: String?, progress: (any ProgressSink)?) async throws -> BridgeSendResult {
        let data = try Data(contentsOf: URL(filePath: media.filePath))
        let total = UInt64(data.count)
        for step in 1...10 {
            try await Task.sleep(for: .milliseconds(60))
            progress?.onProgress(done: total * UInt64(step) / 10, total: total)
        }
        let (kind, type): (MessageKind, BridgeMediaType) = switch media.kind {
        case .image: (.image, .image)
        case .video: (.video, .video)
        case .gif: (.gif, .video)
        case .document: (.document, .document)
        }
        let sha = Data(SHA256.hash(data: data))
        let stored = BridgeMedia(
            directPath: "", mediaKey: Data(count: 32), fileSha256: sha, fileEncSha256: sha, fileLength: total, mediaType: type,
            mimetype: media.mimetype, fileName: media.fileName, width: media.width, height: media.height,
            durationSecs: media.durationSecs, jpegThumbnail: media.jpegThumbnail, waveform: nil, pageCount: media.pageCount,
            isAnimated: media.kind == .gif ? true : nil)
        return sent(chat: chat, kind: kind, text: media.caption, media: stored)
    }

    private func sent(chat: String, kind: MessageKind, text: String?, media: BridgeMedia?) -> BridgeSendResult {
        let id = "3EB0" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(18)
        let now = Int64(Date().timeIntervalSince1970)
        let message = BridgeMessage(
            id: id, chatJid: chat, senderJid: ownJid, participant: chat.hasSuffix("@g.us") ? ownJid : nil, fromMe: true,
            timestamp: now, kind: kind, text: text, quoted: nil, media: media, location: nil, contact: nil, poll: nil,
            reactions: [], typeName: nil, pushName: nil, status: .sent, isForwarded: false, revoked: false, editedAt: nil)
        deliver([.serverAck(ack: BridgeServerAck(chatJid: chat, messageId: id, error: nil))], after: 0.2)
        for (delay, receipt) in [(1.0, ReceiptKind.delivered), (3.0, .read)] {
            deliver([.receipt(receipt: BridgeReceipt(chatJid: chat, senderJid: chat, messageIds: [id], kind: receipt,
                                                     timestamp: now + Int64(delay)))], after: delay)
        }
        return BridgeSendResult(messageId: id, timestamp: now, message: message)
    }

    /// Off the caller's thread: the router blocks until ingest has committed persisted events.
    private func deliver(_ events: [BridgeEvent], after seconds: Double = 0) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [sink] in _ = sink?.onEvents(events: events) }
    }

    // MARK: Media, avatars, groups

    func downloadMedia(media: BridgeMedia, destPath: String, progress: (any ProgressSink)?) async throws {
        let name = media.directPath.split(separator: "/").last.map(String.init) ?? ""
        let source = Demo.resources.appending(path: "media").appending(path: name)
        guard !name.isEmpty, FileManager.default.fileExists(atPath: source.path) else { throw BridgeError.NotFound(media.directPath) }
        try FileManager.default.copyItem(at: source, to: URL(filePath: destPath))
        progress?.onProgress(done: 1, total: 1)
    }

    func profilePicture(jid: String, commonGid: String?, preview: Bool, destPath: String) async throws -> Bool {
        let source = Demo.resources.appending(path: "avatars/\(jid).jpg")
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        try? FileManager.default.removeItem(atPath: destPath)
        try FileManager.default.copyItem(at: source, to: URL(filePath: destPath))
        return true
    }

    func listParticipatingGroups() async throws -> [String] { [] }

    func fetchGroupMetadata(jid: String) async throws -> BridgeGroup {
        try await database.reader.read { db in
            let subject = try String.fetchOne(db, sql: "SELECT name FROM chat WHERE jid = ?", arguments: [jid])
            let participants = try Row.fetchAll(db, sql: "SELECT jid, isAdmin, isSuperAdmin FROM group_participant WHERE groupJid = ?",
                                                arguments: [jid]).map {
                BridgeGroupParticipant(jid: $0["jid"], isAdmin: $0["isAdmin"], isSuperAdmin: $0["isSuperAdmin"])
            }
            return BridgeGroup(jid: jid, subject: subject, participantCount: UInt32(participants.count), participants: participants,
                               membershipChanged: false)
        }
    }

    func fetchGroupOverviews(jids: [String]) async throws -> [BridgeGroup] { [] }
    func checkBusiness(jids: [String]) async throws -> [BridgeBusinessCheck] {
        jids.map { BridgeBusinessCheck(jid: $0, isBusiness: false, verifiedName: nil) }
    }

    // MARK: No-ops

    func archiveChat(chat: String, archived: Bool) async throws {}
    func cancelPairing() async throws {}
    func dataDir() -> String { WAKit.dataDirectory.path }
    func disconnect() async throws {}
    func editMessage(target: BridgeMessageKey, text: String) async throws {}
    func importCapture(captureDir: String) async throws {}
    func logout() async throws {}
    func markChatRead(chat: String, read: Bool) async throws {}
    func markRead(chat: String, messages: [BridgeMessageKey]) async throws -> [BridgeReceiptBatch] { [] }
    func muteChat(chat: String, until: Int64?) async throws {}
    func nudgeReconnect() {}
    func pairWithPhone(number: String) async throws -> String { "" }
    func pinChat(chat: String, pinned: Bool) async throws {}
    func revokeMessage(target: BridgeMessageKey) async throws {}
    func sendChatState(chat: String, state: ChatState) async throws {}
    func sendReaction(target: BridgeMessageKey, emoji: String) async throws {}
    func startPairingQr() async throws {}
    func stats() -> BridgeStats { BridgeStats(eventsReceived: 0, eventsDropped: 0, batchesFlushed: 0) }
    func subscribePresence(jid: String) async throws {}
}
