import Foundation
import GRDB
import os
import Synchronization

/// One bridge batch on its way to `IngestActor`; `committed` is signalled once it has been applied.
struct IngestBatch: Sendable {
    let events: [BridgeEvent]
    let committed: DispatchSemaphore?
}

/// Receives bridge batches on the bridge's dedicated sink thread (never a tokio worker, never the
/// main thread). Batches that ingest persists block here until their transaction has committed:
/// the bridge treats `onEvents` returning as "persisted" and only then lets the library ack the
/// server (durability hook) or send the next history chunk. Ingest never waits on this thread or
/// the main actor, so the wait cannot deadlock.
final class EventRouter: EventSink, Sendable {
    private let ingest: AsyncStream<IngestBatch>.Continuation
    private let session: AsyncStream<[SessionEvent]>.Continuation
    private let presence: AsyncStream<BridgeChatPresence>.Continuation

    init(ingest: AsyncStream<IngestBatch>.Continuation, session: AsyncStream<[SessionEvent]>.Continuation,
         presence: AsyncStream<BridgeChatPresence>.Continuation) {
        self.ingest = ingest
        self.session = session
        self.presence = presence
    }

    func onEvents(events: [BridgeEvent]) {
        let s = events.compactMap(SessionEvent.init)
        if !s.isEmpty { session.yield(s) }
        for case .chatPresence(let p) in events { presence.yield(p) }
        guard events.contains(where: \.isPersisted) else {
            ingest.yield(IngestBatch(events: events, committed: nil))
            return
        }
        let committed = DispatchSemaphore(value: 0)
        guard case .enqueued = ingest.yield(IngestBatch(events: events, committed: committed)) else { return }
        committed.wait()
    }
}

/// Sends read receipts for messages that arrived while their chat was open, batched per chat.
actor ReadReceiptBatcher {
    private let bridge: any WaBridgeProtocol
    private let delay: Duration
    private var pending: [String: [BridgeMessageKey]] = [:]
    private var scheduled = false

    init(bridge: any WaBridgeProtocol, delay: Duration = .milliseconds(300)) {
        self.bridge = bridge
        self.delay = delay
    }

    func add(_ keys: [String: [BridgeMessageKey]]) {
        for (chat, k) in keys { pending[chat, default: []].append(contentsOf: k) }
        guard !scheduled, !pending.isEmpty else { return }
        scheduled = true
        Task {
            try? await Task.sleep(for: delay)
            await flush()
        }
    }

    private func flush() async {
        let batch = pending
        pending = [:]
        scheduled = false
        for (chat, keys) in batch {
            do { try await bridge.markRead(chat: chat, messages: keys) } catch {
                WAKit.log.error("markRead \(chat, privacy: .private) failed: \(error)")
            }
        }
    }
}

/// Forwards Rust `log`/`tracing` output to `os.Logger`.
final class BridgeLogForwarder: LogSink, Sendable {
    let logger = Logger(subsystem: "live.gosupernova.BetterWA", category: "bridge")

    func onLog(level: LogLevel, target: String, message: String) {
        switch level {
        case .error: logger.error("[\(target, privacy: .public)] \(message, privacy: .public)")
        case .warn: logger.warning("[\(target, privacy: .public)] \(message, privacy: .public)")
        case .info: logger.info("[\(target, privacy: .public)] \(message, privacy: .public)")
        case .debug, .trace: logger.debug("[\(target, privacy: .public)] \(message, privacy: .public)")
        }
    }

    private static let installed = Mutex(false)

    /// Installs the forwarder once per process. Must run before the first `WaBridge` is created.
    static func installOnce() {
        let first = installed.withLock { done in
            defer { done = true }
            return !done
        }
        guard first else { return }
        #if DEBUG
        installLogger(sink: BridgeLogForwarder(), maxLevel: .debug)
        #else
        installLogger(sink: BridgeLogForwarder(), maxLevel: .info)
        #endif
    }
}

/// Owns the `WaBridge` and wires it to the database: events flow into `IngestActor` and
/// `SessionService`; UI actions go out through here with optimistic local writes.
public final class WAClient: Sendable {
    public let database: AppDatabase
    public let ingest: IngestActor
    public let bridge: any WaBridgeProtocol
    public let session: SessionService
    public let media: MediaStore
    public let groups: GroupService
    public let avatars: AvatarService
    public var feed: MessageChangeFeed { ingest.feed }
    public var focus: ChatFocus { ingest.focus }
    /// Typing/recording/paused notifications, not persisted. Single consumer (the chat list).
    public let chatPresence: AsyncStream<BridgeChatPresence>

    private let router: EventRouter
    private let ownJidState: Mutex<String?>

    /// `dataDir` holds the Rust session store (`wa-session.sqlite`).
    @MainActor
    public convenience init(database: AppDatabase, dataDir: URL = URL.applicationSupportDirectory.appending(path: "BetterWA")) throws {
        BridgeLogForwarder.installOnce()
        try self.init(database: database) { sink in try WaBridge(dataDir: dataDir.path, sink: sink) }
    }

    /// Injectable bridge for tests.
    @MainActor
    public init(database: AppDatabase, makeBridge: (any EventSink) throws -> any WaBridgeProtocol) throws {
        self.database = database
        let ingest = try IngestActor(database: database)
        self.ingest = ingest

        let (ingestStream, ingestCont) = AsyncStream<IngestBatch>.makeStream(bufferingPolicy: .unbounded)
        let (sessionStream, sessionCont) = AsyncStream<[SessionEvent]>.makeStream(bufferingPolicy: .unbounded)
        let (presenceStream, presenceCont) = AsyncStream<BridgeChatPresence>.makeStream(bufferingPolicy: .bufferingNewest(64))
        chatPresence = presenceStream
        router = EventRouter(ingest: ingestCont, session: sessionCont, presence: presenceCont)
        let bridge = try makeBridge(router)
        self.bridge = bridge

        let ownJid = try database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'ownPn'")
        }
        ownJidState = Mutex(ownJid)
        let session = SessionService(bridge: bridge, ownJid: ownJid)
        self.session = session
        media = MediaStore(bridge: bridge, ingest: ingest)
        let groups = GroupService(bridge: bridge, ingest: ingest)
        self.groups = groups
        avatars = AvatarService(bridge: bridge, ingest: ingest)
        let receipts = ReadReceiptBatcher(bridge: bridge)

        // Single consumer: batches are applied one at a time, in bridge order.
        Task.detached(priority: .userInitiated) {
            try? await ingest.prunePendingMutations(olderThan: Int64(Date().timeIntervalSince1970) - 14 * 86_400)
            for await batch in ingestStream {
                var reads: [String: [BridgeMessageKey]] = [:]
                do { reads = try await ingest.applyBatch(batch.events) } catch { WAKit.log.error("ingest failed: \(error)") }
                batch.committed?.signal()
                if !reads.isEmpty { await receipts.add(reads) }
                if batch.events.contains(where: \.completesSyncPhase) {
                    Task { await groups.fillMissingNames() }
                }
            }
        }
        Task { @MainActor [weak self] in
            for await events in sessionStream {
                session.handle(events)
                for case .ownJid(let pn, _) in events where pn != nil { self?.ownJidState.withLock { $0 = pn } }
                for case .pairing(.success(let jid, _)) in events { self?.ownJidState.withLock { $0 = jid } }
                for case .pairing(.loggedOut) in events { self?.ownJidState.withLock { $0 = nil } }
            }
        }
    }

    public var ownJid: String? { ownJidState.withLock { $0 } }

    // MARK: Session

    public func connect() async throws { try await bridge.connect() }
    public func disconnect() async throws { try await bridge.disconnect() }
    public func startPairingQr() async throws { try await bridge.startPairingQr() }
    public func pairWithPhone(_ number: String) async throws -> String { try await bridge.pairWithPhone(number: number) }
    public func cancelPairing() async throws { try await bridge.cancelPairing() }
    /// Unlinks this Mac. The bridge drops its client and session store; our identity is forgotten
    /// so the next launch (or "Link again") starts unpaired.
    public func logout() async throws {
        try await bridge.logout()
        try await ingest.forgetOwnIdentity()
        ownJidState.withLock { $0 = nil }
    }

    // MARK: Reading

    public func windowLoader(for chatJid: String) -> ChatWindowLoader {
        ChatWindowLoader(database: database, chatJid: chatJid)
    }

    /// Tell ingest which chat is visible; incoming messages there do not count as unread while the window is key.
    public func setFocus(chatJid: String?, windowIsKey: Bool) {
        focus.set(chatJid: chatJid, windowIsKey: windowIsKey)
    }

    /// Clears unread state locally and sends read receipts. Call when a chat is shown in a key window.
    public func openChat(_ chatJid: String) async {
        focus.set(chatJid: chatJid, windowIsKey: true)
        do {
            let result = try await ingest.chatOpened(chatJid)
            if !result.unreadKeys.isEmpty { try await bridge.markRead(chat: chatJid, messages: result.unreadKeys) }
            if result.wasMarkedUnread { try await bridge.markChatRead(chat: chatJid, read: true) }
        } catch {
            WAKit.log.error("openChat \(chatJid, privacy: .private) failed: \(error)")
        }
    }

    /// Makes sure a chat exists for `jid` (a contact with no chat yet) and returns its canonical JID.
    public func startChat(with jid: String) async throws -> String {
        try await ingest.createLocalChat(jid)
    }

    // MARK: Sending (optimistic)

    /// Inserts a pending row, sends, then marks it sent (server id) or failed. Returns the local id.
    @discardableResult
    public func sendText(_ text: String, to chatJid: String, replyTo: MessageItem? = nil) async throws -> String {
        let pending = try await ingest.insertOutgoing(
            chatJid: chatJid, text: text, quoted: replyTo.map(Self.quote), ownJid: ownJid)
        await performSend(localId: pending.id, chatJid: chatJid) { [bridge] in
            try await bridge.sendText(chat: chatJid, text: text, replyTo: replyTo?.message.key)
        }
        return pending.id
    }

    /// Inserts one optimistic row per attachment (in order) and uploads them one at a time. The caption
    /// and reply go on the first item, as in WhatsApp's own clients. Returns the local ids.
    @discardableResult
    public func sendAttachments(_ items: [PreparedAttachment], caption: String?, to chatJid: String,
                                replyTo: MessageItem? = nil) async throws -> [String] {
        var queued: [(String, BridgeOutgoingMedia, MessageItem?)] = []
        for (i, item) in items.enumerated() {
            var outgoing = item.outgoing
            outgoing.caption = i == 0 ? caption.flatMap { $0.isEmpty ? nil : $0 } : nil
            let reply = i == 0 ? replyTo : nil
            let pending = try await insertPendingMedia(outgoing, to: chatJid, replyTo: reply)
            queued.append((pending.id, outgoing, reply))
        }
        for (localId, outgoing, reply) in queued {
            await uploadAndSend(localId: localId, outgoing: outgoing, chatJid: chatJid, replyKey: reply?.message.key)
        }
        return queued.map(\.0)
    }

    @discardableResult
    public func sendMedia(_ outgoing: BridgeOutgoingMedia, to chatJid: String, replyTo: MessageItem? = nil) async throws -> String {
        let pending = try await insertPendingMedia(outgoing, to: chatJid, replyTo: replyTo)
        await uploadAndSend(localId: pending.id, outgoing: outgoing, chatJid: chatJid, replyKey: replyTo?.message.key)
        return pending.id
    }

    private func insertPendingMedia(_ outgoing: BridgeOutgoingMedia, to chatJid: String, replyTo: MessageItem?) async throws -> MessageItem {
        try await ingest.insertOutgoing(
            chatJid: chatJid, text: outgoing.caption, kind: outgoing.kind.messageKind,
            quoted: replyTo.map(Self.quote), media: outgoing, ownJid: ownJid)
    }

    /// Uploads with progress on the optimistic row, moves the file into the media store, and removes
    /// a converted staging copy once it is stored.
    private func uploadAndSend(localId: String, outgoing: BridgeOutgoingMedia, chatJid: String, replyKey: BridgeMessageKey?) async {
        let jid = await ingest.canonicalJid(chatJid)
        let relay = media.uploadRelay(chatJid: jid, localId: localId)
        let source = URL(filePath: outgoing.filePath)
        await performSend(localId: localId, chatJid: chatJid) { [bridge, media] in
            defer { media.clearUploadProgress(chatJid: jid, localId: localId) }
            let result = try await bridge.sendMedia(chat: chatJid, media: outgoing, replyTo: replyKey, progress: relay)
            guard let m = result.message.media else { return (result, nil) }
            let stored = await media.adoptSentFile(source, for: IngestActor.mediaRecord(m, chatJid: jid, messageId: result.messageId))
            if stored != nil, source.path.hasPrefix(OutgoingMediaPreparer.stagingDirectory.path) {
                try? FileManager.default.removeItem(at: source)
            }
            return (result, stored?.path)
        }
    }

    /// Re-sends a failed optimistic message.
    public func retry(localId: String, chatJid: String) async throws {
        guard let item = try await windowLoader(for: chatJid).items(ids: [localId]).first,
              item.message.status == .failed else { return }
        try await ingest.markPending(localId: localId, chatJid: chatJid)
        let text = item.message.text
        if let m = item.media, let path = m.localPath {
            let outgoing = BridgeOutgoingMedia(
                kind: item.message.kind.sendKind, filePath: path, mimetype: m.mimetype ?? "application/octet-stream",
                fileName: m.fileName, caption: text, width: m.width.map(UInt32.init), height: m.height.map(UInt32.init),
                durationSecs: m.durationSecs.map(UInt32.init), jpegThumbnail: m.jpegThumbnail,
                thumbnailWidth: nil, thumbnailHeight: nil, pageCount: m.pageCount.map(UInt32.init))
            await uploadAndSend(localId: localId, outgoing: outgoing, chatJid: chatJid, replyKey: nil)
        } else if let text {
            await performSend(localId: localId, chatJid: chatJid) { [bridge] in
                try await bridge.sendText(chat: chatJid, text: text, replyTo: nil)
            }
        }
    }

    private func performSend(localId: String, chatJid: String, _ send: @Sendable () async throws -> BridgeSendResult) async {
        await performSend(localId: localId, chatJid: chatJid) { (try await send(), nil) }
    }

    private func performSend(localId: String, chatJid: String, _ send: @Sendable () async throws -> (BridgeSendResult, String?)) async {
        do {
            let (result, storedPath) = try await send()
            try await ingest.completeSend(localId: localId, chatJid: chatJid, result: result, storedPath: storedPath)
        } catch {
            WAKit.log.error("send failed: \(error)")
            try? await ingest.failSend(localId: localId, chatJid: chatJid)
        }
    }

    static func quote(_ item: MessageItem) -> BridgeQuoted {
        BridgeQuoted(id: item.message.id, senderJid: item.message.senderJid, kind: item.message.kind,
                     snippet: String((item.message.text ?? "").prefix(200)))
    }

    // MARK: Message actions

    /// Toggle semantics are the caller's: pass "" to remove your reaction.
    public func react(to key: BridgeMessageKey, emoji: String) async throws {
        let reaction = BridgeReaction(senderJid: ownJid ?? "", fromMe: true, emoji: emoji, timestamp: Int64(Date().timeIntervalSince1970))
        try await ingest.apply([.messages(messages: [], updates: [.reaction(target: key, reaction: reaction)])])
        try await bridge.sendReaction(target: key, emoji: emoji)
    }

    public func edit(_ key: BridgeMessageKey, text: String) async throws {
        try await bridge.editMessage(target: key, text: text)
        try await ingest.apply([.messages(messages: [], updates: [
            .edit(target: key, text: text, editedAt: Int64(Date().timeIntervalSince1970)),
        ])])
    }

    public func revoke(_ key: BridgeMessageKey) async throws {
        try await bridge.revokeMessage(target: key)
        try await ingest.apply([.messages(messages: [], updates: [
            .revoke(target: key, revokedBy: ownJid ?? "", timestamp: Int64(Date().timeIntervalSince1970)),
        ])])
    }

    public func sendChatState(_ state: ChatState, in chatJid: String) async {
        try? await bridge.sendChatState(chat: chatJid, state: state)
    }

    public func subscribePresence(_ jid: String) async {
        try? await bridge.subscribePresence(jid: jid)
    }

    // MARK: Chat actions (optimistic locally, then synced)

    public func setPinned(_ chatJid: String, _ pinned: Bool) async throws {
        try await ingest.applyLocal(.pin(chatJid: chatJid, pinnedAt: pinned ? Int64(Date().timeIntervalSince1970) : nil))
        try await bridge.pinChat(chat: chatJid, pinned: pinned)
    }

    /// `nil` unmutes; `Int64.max` mutes forever.
    public func setMuted(_ chatJid: String, until: Int64?) async throws {
        try await ingest.applyLocal(.mute(chatJid: chatJid, mutedUntil: until))
        try await bridge.muteChat(chat: chatJid, until: until)
    }

    public func setArchived(_ chatJid: String, _ archived: Bool) async throws {
        try await ingest.applyLocal(.archive(chatJid: chatJid, archived: archived))
        try await bridge.archiveChat(chat: chatJid, archived: archived)
    }

    /// `read == false` marks the chat unread.
    public func setRead(_ chatJid: String, _ read: Bool) async throws {
        try await ingest.applyLocal(.markRead(chatJid: chatJid, read: read))
        try await bridge.markChatRead(chat: chatJid, read: read)
    }
}

extension BridgeEvent {
    /// Events `IngestActor` writes to the database; batches containing one wait for its commit.
    var isPersisted: Bool {
        switch self {
        case .connection, .pairing, .chatPresence, .presence, .offlineSyncCompleted: false
        default: true
        }
    }

    /// Points after which group names are worth back-filling.
    var completesSyncPhase: Bool {
        switch self {
        case .historyChunk(let c): c.isLastInPayload
        case .offlineSyncCompleted: true
        default: false
        }
    }
}

extension SendMediaKind {
    var messageKind: MessageKind {
        switch self {
        case .image: .image
        case .video: .video
        case .gif: .gif
        case .document: .document
        }
    }
}

extension MessageKind {
    var sendKind: SendMediaKind {
        switch self {
        case .image: .image
        case .video: .video
        case .gif: .gif
        default: .document
        }
    }
}
