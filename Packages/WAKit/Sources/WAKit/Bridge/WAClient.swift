import Foundation
import GRDB
import os
import Synchronization

/// Receives bridge batches on the Rust thread and hands them off without blocking it.
final class EventRouter: EventSink, Sendable {
    private let ingest: AsyncStream<[BridgeEvent]>.Continuation
    private let session: AsyncStream<[SessionEvent]>.Continuation
    private let presence: AsyncStream<BridgeChatPresence>.Continuation

    init(ingest: AsyncStream<[BridgeEvent]>.Continuation, session: AsyncStream<[SessionEvent]>.Continuation,
         presence: AsyncStream<BridgeChatPresence>.Continuation) {
        self.ingest = ingest
        self.session = session
        self.presence = presence
    }

    func onEvents(events: [BridgeEvent]) {
        ingest.yield(events)
        let s = events.compactMap(SessionEvent.init)
        if !s.isEmpty { session.yield(s) }
        for case .chatPresence(let p) in events { presence.yield(p) }
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

        let (ingestStream, ingestCont) = AsyncStream<[BridgeEvent]>.makeStream(bufferingPolicy: .unbounded)
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

        Task.detached(priority: .userInitiated) {
            try? await ingest.prunePendingMutations(olderThan: Int64(Date().timeIntervalSince1970) - 14 * 86_400)
            for await batch in ingestStream {
                do { try await ingest.apply(batch) } catch { WAKit.log.error("ingest failed: \(error)") }
                if batch.contains(where: \.completesSyncPhase) {
                    Task { await groups.fillMissingNames() }
                }
            }
        }
        Task { @MainActor [weak self] in
            for await events in sessionStream {
                session.handle(events)
                for case .ownJid(let pn, _) in events where pn != nil { self?.ownJidState.withLock { $0 = pn } }
                for case .pairing(.success(let jid, _)) in events { self?.ownJidState.withLock { $0 = jid } }
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
    public func logout() async throws { try await bridge.logout() }

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

    @discardableResult
    public func sendMedia(_ outgoing: BridgeOutgoingMedia, to chatJid: String, replyTo: MessageItem? = nil,
                          progress: (any ProgressSink)? = nil) async throws -> String {
        let pending = try await ingest.insertOutgoing(
            chatJid: chatJid, text: outgoing.caption, kind: outgoing.kind.messageKind,
            quoted: replyTo.map(Self.quote), media: outgoing, ownJid: ownJid)
        await performSend(localId: pending.id, chatJid: chatJid) { [bridge, media] in
            let result = try await bridge.sendMedia(chat: chatJid, media: outgoing, replyTo: replyTo?.message.key, progress: progress)
            if let m = result.message.media {
                await media.adoptSentFile(URL(filePath: outgoing.filePath),
                                          for: IngestActor.mediaRecord(m, chatJid: chatJid, messageId: result.messageId))
            }
            return result
        }
        return pending.id
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
                durationSecs: m.durationSecs.map(UInt32.init), jpegThumbnail: m.jpegThumbnail, pageCount: m.pageCount.map(UInt32.init))
            await performSend(localId: localId, chatJid: chatJid) { [bridge] in
                try await bridge.sendMedia(chat: chatJid, media: outgoing, replyTo: nil, progress: nil)
            }
        } else if let text {
            await performSend(localId: localId, chatJid: chatJid) { [bridge] in
                try await bridge.sendText(chat: chatJid, text: text, replyTo: nil)
            }
        }
    }

    private func performSend(localId: String, chatJid: String, _ send: @Sendable () async throws -> BridgeSendResult) async {
        do {
            let result = try await send()
            try await ingest.completeSend(localId: localId, chatJid: chatJid, result: result)
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
