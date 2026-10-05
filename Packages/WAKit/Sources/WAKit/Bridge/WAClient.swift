import Foundation
import GRDB
import os
import Synchronization

/// One bridge batch on its way to `IngestActor`; `done` is signalled once it has been applied
/// (or has failed).
struct IngestBatch: Sendable {
    let events: [BridgeEvent]
    let done: IngestCompletion?
}

/// Lets the sink thread wait for a batch's transaction and learn whether it committed.
final class IngestCompletion: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let result = Mutex(false)

    func finish(committed: Bool) {
        result.withLock { $0 = committed }
        semaphore.signal()
    }

    /// Blocks until `finish`; returns whether the batch committed.
    func wait() -> Bool {
        semaphore.wait()
        return result.withLock { $0 }
    }
}

/// Receives bridge batches on the bridge's dedicated sink thread (never a tokio worker, never the
/// main thread). Batches that ingest persists block here until their transaction has finished,
/// and `onEvents` reports whether it committed: only then does the bridge let the library ack the
/// server (durability hook; `false` leaves the messages unacked for redelivery) or send the next
/// history chunk. Ingest never waits on this thread or the main actor, so the wait cannot deadlock.
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

    func onEvents(events: [BridgeEvent]) -> Bool {
        let s = events.compactMap(SessionEvent.init)
        if !s.isEmpty { session.yield(s) }
        for case .chatPresence(let p) in events { presence.yield(p) }
        guard events.contains(where: \.isPersisted) else {
            ingest.yield(IngestBatch(events: events, done: nil))
            return true
        }
        let done = IngestCompletion()
        guard case .enqueued = ingest.yield(IngestBatch(events: events, done: done)) else { return false }
        return done.wait()
    }
}

/// Retries parked encrypted add-ons (edits, poll votes that arrived before their original) whose
/// target is stored. The first try runs right after the target's commit, but the library may not
/// have flushed the parent's secret to its store yet, so a sweep follows after a short delay and on
/// every connect. Each envelope gets `maxAttempts` tries per session; what never opens stays parked
/// until the 14-day prune.
actor ParkedRetrier {
    static let maxAttempts = 4
    static let sweepLimit = 200

    private let ingest: IngestActor
    private let bridge: any WaBridgeProtocol
    private let delay: Duration
    private var attempts: [Int64: Int] = [:]
    private var scheduled = false

    init(ingest: IngestActor, bridge: any WaBridgeProtocol, delay: Duration = .seconds(3)) {
        self.ingest = ingest
        self.bridge = bridge
        self.delay = delay
    }

    /// Tries `parked` now (targets just committed).
    func retry(_ parked: [ParkedEnvelope]) async {
        let due = parked.filter { attempts[$0.rowId, default: 0] < Self.maxAttempts }
        guard !due.isEmpty else { return }
        for p in due { attempts[p.rowId, default: 0] += 1 }
        do {
            let bridge = self.bridge
            let opened = try await ingest.retryParked(due) { await bridge.decryptParked(envelopes: $0) }
            for id in opened { attempts[id] = nil }
        } catch {
            WAKit.log.error("parked add-on retry failed: \(error)")
        }
    }

    /// One pass over every parked add-on whose target is stored.
    func sweep() async {
        do {
            let ready = try await ingest.parkedEncryptedReady(limit: Self.sweepLimit * Self.maxAttempts)
            await retry(Array(ready.filter { attempts[$0.rowId, default: 0] < Self.maxAttempts }.prefix(Self.sweepLimit)))
        } catch {
            WAKit.log.error("parked add-on sweep failed: \(error)")
        }
    }

    /// Runs `sweep` after the delay; calls while one is pending coalesce.
    func scheduleSweep() {
        guard !scheduled else { return }
        scheduled = true
        Task {
            try? await Task.sleep(for: delay)
            await runScheduled()
        }
    }

    private func runScheduled() async {
        scheduled = false
        await sweep()
    }
}

/// Resends our messages the server never acked, under their ids: after a reconnect, and a while
/// after a send in case the ack goes missing without the connection dropping. One pass at a time.
/// Nothing is resent while disconnected; the reconnect resends it. A send error leaves the message
/// pending for the next pass; after `maxAttempts` sends that were never acked, it fails, for a
/// manual retry. A message being sent (by a pass or a manual retry) is claimed until that send ends.
actor SendRecovery {
    static let ackTimeout: Duration = .seconds(30)
    static let maxAttempts = 3

    private let ingest: IngestActor
    private let bridge: any WaBridgeProtocol
    private let media: MediaStore
    private let clock = ContinuousClock()
    private var attempts: [String: (count: Int, at: ContinuousClock.Instant)] = [:]
    private var sending: Set<String> = []
    private var connected = false
    private var running = false
    private var again: Bool?
    private var checkScheduled = false

    init(ingest: IngestActor, bridge: any WaBridgeProtocol, media: MediaStore) {
        self.ingest = ingest
        self.bridge = bridge
        self.media = media
    }

    func setConnected(_ connected: Bool) { self.connected = connected }

    /// `reconnected`: resend everything unacked; otherwise only what has waited `ackTimeout`.
    func run(reconnected: Bool) async {
        if running {
            again = (again ?? false) || reconnected
            return
        }
        running = true
        var all = reconnected
        while true {
            await pass(all: all)
            guard let next = again else { break }
            again = nil
            all = next
        }
        running = false
    }

    func scheduleCheck() {
        guard !checkScheduled else { return }
        checkScheduled = true
        Task {
            try? await Task.sleep(for: Self.ackTimeout)
            await self.runScheduledCheck()
        }
    }

    /// A manual retry of a failed message: starts its attempts over and reports failure at once.
    func retry(_ item: MessageItem, quoted: BridgeMessageKey?) async {
        let m = item.message
        let key = Self.key(m)
        attempts[key] = (1, clock.now)
        guard sending.insert(key).inserted else { return }
        defer { sending.remove(key) }
        do {
            try await send(item, quoted: quoted)
            scheduleCheck()
        } catch {
            WAKit.log.error("retry \(m.id, privacy: .public) failed: \(error)")
            try? await ingest.failSend(localId: m.id, chatJid: m.chatJid)
        }
    }

    private func runScheduledCheck() async {
        checkScheduled = false
        await run(reconnected: false)
    }

    private func pass(all: Bool) async {
        guard connected else { return }
        let unacked: [(item: MessageItem, quoted: BridgeMessageKey?)]
        do { unacked = try await ingest.unackedSends() } catch {
            WAKit.log.error("unacked sends: \(error)")
            return
        }
        let live = Set(unacked.map { Self.key($0.item.message) })
        attempts = attempts.filter { live.contains($0.key) }
        let now = clock.now
        for (item, quoted) in unacked {
            let m = item.message
            let key = Self.key(m)
            guard connected, !sending.contains(key) else { continue }
            let previous = attempts[key]
            if !all {
                let waited = previous.map { now - $0.at } ?? .seconds(Int64(Date().timeIntervalSince1970) - m.timestamp)
                guard waited >= Self.ackTimeout else { continue }
            }
            // An ack may have landed since the snapshot.
            guard (try? await ingest.isUnacked(chatJid: m.chatJid, id: m.id)) == true else { continue }
            let count = (previous?.count ?? 0) + 1
            if count > Self.maxAttempts {
                WAKit.log.error("\(m.id, privacy: .public) never acked; giving up")
                attempts[key] = nil
                try? await ingest.failSend(localId: m.id, chatJid: m.chatJid)
                continue
            }
            attempts[key] = (count, clock.now)
            sending.insert(key)
            do { try await send(item, quoted: quoted) } catch {
                WAKit.log.error("resend \(m.id, privacy: .public) failed: \(error)")
                // Dropped while sending: the reconnect sends it again, and this one doesn't count.
                if !connected { attempts[key] = previous }
            }
            sending.remove(key)
        }
        if !unacked.isEmpty { scheduleCheck() }
        try? await ingest.dropUnclaimedAcks()
    }

    /// Media goes out with its file again, never as its caption alone.
    private func send(_ item: MessageItem, quoted: BridgeMessageKey?) async throws {
        let m = item.message
        if item.media != nil {
            guard let outgoing = Self.outgoingMedia(item, media: media) else {
                throw BridgeError.NotFound("file for \(m.id)")
            }
            let result = try await bridge.sendMedia(chat: m.chatJid, media: outgoing, replyTo: quoted, messageId: m.id, progress: nil)
            if let media = result.message.media {
                try? await ingest.refreshSentMedia(chatJid: m.chatJid, id: m.id, media: media)
            }
        } else if let text = m.text {
            _ = try await bridge.sendText(chat: m.chatJid, text: text, mentions: m.extra?.mentions ?? [], replyTo: quoted, messageId: m.id)
        } else {
            throw BridgeError.NotImplemented("resend of \(m.kind)")
        }
    }

    /// The staged file for a send in progress, else the copy the media store kept.
    static func outgoingMedia(_ item: MessageItem, media store: MediaStore) -> BridgeOutgoingMedia? {
        guard let m = item.media,
              let path = m.sourcePath.flatMap({ FileManager.default.fileExists(atPath: $0) ? $0 : nil })
                ?? store.localURL(for: m)?.path else { return nil }
        return BridgeOutgoingMedia(
            kind: item.message.kind.sendKind, filePath: path, mimetype: m.mimetype ?? "application/octet-stream",
            fileName: m.fileName, caption: item.message.text, width: m.width.map(UInt32.init), height: m.height.map(UInt32.init),
            durationSecs: m.durationSecs.map(UInt32.init), jpegThumbnail: m.jpegThumbnail,
            thumbnailWidth: nil, thumbnailHeight: nil, pageCount: m.pageCount.map(UInt32.init),
            mentions: item.message.extra?.mentions ?? [])
    }

    private static func key(_ m: MessageRecord) -> String { m.chatJid + "/" + m.id }
}

/// Sends what ingest queued in `outbox`: read receipts (one bridge call per chat), reactions,
/// edits, revokes and chat actions. Each bridge call returns once the server confirmed it, and only
/// then does the row go. A failure leaves it for the next pass: the next change, a reconnect, or
/// `retryDelay` later while connected. Failures with the connection up count; after `maxAttempts`
/// ingest gives up on the row and undoes the local change. Nothing is counted while disconnected,
/// and a pass stops at the first failure then. One pass at a time; calls during one run another
/// after it.
actor Outbox {
    static let maxAttempts = 5

    private let ingest: IngestActor
    private let bridge: any WaBridgeProtocol
    private let delay: Duration
    private let retryDelay: Duration
    private var connected = false
    private var scheduled = false
    private var retryScheduled = false
    private var running = false
    private var again = false

    init(ingest: IngestActor, bridge: any WaBridgeProtocol, delay: Duration = .milliseconds(300), retryDelay: Duration = .seconds(30)) {
        self.ingest = ingest
        self.bridge = bridge
        self.delay = delay
        self.retryDelay = retryDelay
    }

    func setConnected(_ connected: Bool) { self.connected = connected }

    /// Flushes after `delay`, so changes made together (receipts for messages arriving together)
    /// go out in one pass.
    func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task {
            try? await Task.sleep(for: delay)
            await runScheduled()
        }
    }

    func flush() async {
        if running {
            again = true
            return
        }
        running = true
        var failed = false
        repeat {
            again = false
            failed = await pass()
        } while again
        running = false
        if failed, connected { scheduleRetry() }
    }

    private func runScheduled() async {
        scheduled = false
        await flush()
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        Task {
            try? await Task.sleep(for: retryDelay)
            await runRetry()
        }
    }

    private func runRetry() async {
        retryScheduled = false
        await flush()
    }

    /// Returns whether anything failed.
    private func pass() async -> Bool {
        let due: OutboxDue
        do { due = try await ingest.outboxDue() } catch {
            WAKit.log.error("outbox: \(error)")
            return true
        }
        var failed = false
        for r in due.receipts {
            guard await attempt(r.rowIds, "receipts", { [bridge] in try await bridge.markRead(chat: r.chatJid, messages: r.keys) }) else {
                failed = true
                if !connected { return true }
                continue
            }
        }
        for e in due.changes {
            // Changes made or received while this pass waited on earlier sends may have replaced it.
            guard (try? await ingest.claimOutbox(e)) == true else { continue }
            guard await attempt([e.id], e.change.kind, entry: e, { try await self.send(e) }) else {
                failed = true
                if !connected { return true }
                continue
            }
        }
        return failed
    }

    private func attempt(_ ids: [Int64], _ what: String, entry: OutboxEntry? = nil, _ body: @Sendable () async throws -> Void) async -> Bool {
        let wasConnected = connected
        do {
            try await body()
        } catch {
            WAKit.log.error("outbox: \(what, privacy: .public) failed: \(error)")
            // The connection dropped under it (`NotConnected`, even without a disconnect event):
            // not the row's fault.
            var dropped = false
            if case BridgeError.NotConnected = error { dropped = true }
            _ = try? await ingest.outboxFailed(ids, entry: entry, error: "\(error)", counted: wasConnected && connected && !dropped,
                                               maxAttempts: Self.maxAttempts)
            return false
        }
        // Confirmed: a failure to record it must not send it again.
        do { try await ingest.outboxSent(ids, entry: entry) } catch {
            WAKit.log.error("outbox: recording a confirmed \(what, privacy: .public) failed: \(error)")
        }
        return true
    }

    private func send(_ e: OutboxEntry) async throws {
        func key(_ fromMe: Bool, _ participant: String?) -> BridgeMessageKey {
            BridgeMessageKey(chatJid: e.chatJid, id: e.messageId, fromMe: fromMe, participant: participant)
        }
        switch e.change {
        case .receipt:
            break
        case .reaction(let fromMe, let participant, let emoji, _, _):
            try await bridge.sendReaction(target: key(fromMe, participant), emoji: emoji)
        case .edit(let text, _, _, _, let mentions, _):
            try await bridge.editMessage(target: key(true, nil), text: text, mentions: mentions ?? [])
        case .revoke(let fromMe, let participant, _, _):
            try await bridge.revokeMessage(target: key(fromMe, participant))
        case .pin(let pinnedAt, _):
            try await bridge.pinChat(chat: e.chatJid, pinned: pinnedAt != nil)
        case .mute(let until, _):
            try await bridge.muteChat(chat: e.chatJid, until: until)
        case .archive(let archived, _):
            try await bridge.archiveChat(chat: e.chatJid, archived: archived)
        case .markRead(let read, _):
            try await bridge.markChatRead(chat: e.chatJid, read: read)
        }
    }
}

/// Forwards Rust `log`/`tracing` output to `os.Logger`.
final class BridgeLogForwarder: LogSink, Sendable {
    let logger = Logger(subsystem: WAKit.subsystem, category: "bridge")

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
    public let businesses: BusinessService
    public let avatars: AvatarService
    let recovery: SendRecovery
    let outbox: Outbox
    public var feed: MessageChangeFeed { ingest.feed }
    public var focus: ChatFocus { ingest.focus }
    /// Messages to notify about and notifications to withdraw. Single consumer.
    public var notices: AsyncStream<NoticeEvent> { ingest.notices }
    /// Typing/recording/paused notifications, not persisted. Single consumer (the chat list).
    public let chatPresence: AsyncStream<BridgeChatPresence>

    private let router: EventRouter
    private let ownJidState: Mutex<String?>

    /// `dataDir` holds the Rust session store (`wa-session.sqlite`).
    @MainActor
    public convenience init(database: AppDatabase, dataDir: URL = WAKit.dataDirectory) throws {
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
        let media = MediaStore(bridge: bridge, ingest: ingest)
        self.media = media
        let recovery = SendRecovery(ingest: ingest, bridge: bridge, media: media)
        self.recovery = recovery
        let groups = GroupService(bridge: bridge, ingest: ingest)
        self.groups = groups
        let businesses = BusinessService(bridge: bridge, ingest: ingest)
        self.businesses = businesses
        avatars = AvatarService(bridge: bridge, ingest: ingest)
        let outbox = Outbox(ingest: ingest, bridge: bridge)
        self.outbox = outbox
        let retrier = ParkedRetrier(ingest: ingest, bridge: bridge)

        // Single consumer: batches are applied one at a time, in bridge order.
        Task.detached(priority: .userInitiated) {
            let now = Int64(Date().timeIntervalSince1970)
            try? await ingest.prunePendingMutations(olderThan: now - 14 * 86_400, readMarkersOlderThan: now - 60 * 86_400)
            try? await ingest.pruneTombstones(olderThan: now - 90 * 86_400)
            try? await ingest.pruneOutbox(olderThan: now - 14 * 86_400)
            for await batch in ingestStream {
                var result = IngestResult()
                do {
                    result = try await ingest.applyBatch(batch.events)
                    batch.done?.finish(committed: true)
                } catch {
                    WAKit.log.error("ingest failed: \(error)")
                    batch.done?.finish(committed: false)
                }
                if !result.reads.isEmpty { await outbox.schedule() }
                if !result.parked.isEmpty {
                    await retrier.retry(result.parked)
                    await retrier.scheduleSweep()
                }
                if let state = batch.events.last(where: { if case .connection = $0 { true } else { false } }),
                   case .connection(let connection) = state {
                    await recovery.setConnected(connection == .connected)
                    await outbox.setConnected(connection == .connected)
                }
                if batch.events.contains(where: { if case .connection(.connected) = $0 { true } else { false } }) {
                    await retrier.scheduleSweep()
                    Task { await recovery.run(reconnected: true) }
                    Task { await outbox.flush() }
                }
                let staleGroups = batch.events.compactMap { event -> String? in
                    if case .group(let g) = event, g.membershipChanged { g.jid } else { nil }
                }
                if !staleGroups.isEmpty || batch.events.contains(where: \.completesSyncPhase) {
                    Task { await groups.fillMissing(stale: staleGroups) }
                }
                if batch.events.contains(where: { if case .offlineSyncCompleted = $0 { true } else { false } }) {
                    Task { await groups.addMissingJoinedGroups() }
                }
                if batch.events.contains(where: { if case .messages = $0 { true } else { $0.completesSyncPhase } }) {
                    Task { await businesses.checkPending() }
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
        await markRead(chatJid)
    }

    /// Clears unread state locally and sends read receipts without changing focus.
    public func markRead(_ chatJid: String) async {
        do {
            let result = try await ingest.chatOpened(chatJid)
            if !result.unreadKeys.isEmpty || result.wasMarkedUnread { await outbox.flush() }
        } catch {
            WAKit.log.error("markRead \(chatJid, privacy: .private) failed: \(error)")
        }
    }

    /// A group's other members, for mentioning. The first call per group per session asks the server.
    public func groupMembers(_ groupJid: String) async -> [GroupMember] {
        await groups.members(of: groupJid)
    }

    /// Makes sure a chat exists for `jid` (a contact with no chat yet) and returns its canonical JID.
    public func startChat(with jid: String) async throws -> String {
        try await ingest.createLocalChat(jid)
    }

    // MARK: Sending (optimistic)

    /// Inserts a pending row, sends, then marks it sent (server id) or failed. Returns the local id.
    /// `mentions` are the JIDs the text's "@<number>"s stand for (see `Mentions`).
    @discardableResult
    public func sendText(_ text: String, mentions: [String] = [], to chatJid: String, replyTo: MessageItem? = nil) async throws -> String {
        let pending = try await ingest.insertOutgoing(
            chatJid: chatJid, text: text, mentions: mentions, quoted: replyTo.map(Self.quote), ownJid: ownJid)
        await performSend(localId: pending.id, chatJid: chatJid) { [bridge] in
            try await bridge.sendText(chat: chatJid, text: text, mentions: mentions, replyTo: replyTo?.message.key, messageId: nil)
        }
        return pending.id
    }

    /// Inserts one optimistic row per attachment (in order) and uploads them one at a time. The caption
    /// and reply go on the first item, as in WhatsApp's own clients. Returns the local ids.
    @discardableResult
    public func sendAttachments(_ items: [PreparedAttachment], caption: String?, mentions: [String] = [], to chatJid: String,
                                replyTo: MessageItem? = nil) async throws -> [String] {
        var queued: [(String, BridgeOutgoingMedia, MessageItem?)] = []
        for (i, item) in items.enumerated() {
            var outgoing = item.outgoing
            outgoing.caption = i == 0 ? caption.flatMap { $0.isEmpty ? nil : $0 } : nil
            outgoing.mentions = outgoing.caption == nil ? [] : mentions
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
            chatJid: chatJid, text: outgoing.caption, mentions: outgoing.mentions, kind: outgoing.kind.messageKind,
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
            let result = try await bridge.sendMedia(chat: chatJid, media: outgoing, replyTo: replyKey, messageId: nil, progress: relay)
            guard let m = result.message.media else { return (result, false) }
            let stored = await media.adoptSentFile(source, for: IngestActor.mediaRecord(m, chatJid: jid, messageId: result.messageId))
            if stored != nil, source.path.hasPrefix(OutgoingMediaPreparer.stagingDirectory.path) {
                try? FileManager.default.removeItem(at: source)
            }
            return (result, stored != nil)
        }
    }

    /// Re-sends a failed message. One the server already has an id for goes out under that id, so
    /// recipients who did get it don't see it twice.
    public func retry(localId: String, chatJid: String) async throws {
        guard let item = try await windowLoader(for: chatJid).items(ids: [localId]).first,
              item.message.status == .failed else { return }
        try await ingest.markPending(localId: localId, chatJid: chatJid)
        let quoted = try await ingest.quotedKey(of: item.message)
        if !localId.hasPrefix("local-") {
            await recovery.retry(item, quoted: quoted)
        } else if item.media != nil {
            guard let outgoing = SendRecovery.outgoingMedia(item, media: media) else {
                try await ingest.failSend(localId: localId, chatJid: chatJid)
                return
            }
            await uploadAndSend(localId: localId, outgoing: outgoing, chatJid: chatJid, replyKey: quoted)
        } else if let text = item.message.text {
            await performSend(localId: localId, chatJid: chatJid) { [bridge] in
                try await bridge.sendText(chat: chatJid, text: text, mentions: item.message.extra?.mentions ?? [], replyTo: quoted, messageId: nil)
            }
        }
    }

    private func performSend(localId: String, chatJid: String, _ send: @Sendable () async throws -> BridgeSendResult) async {
        await performSend(localId: localId, chatJid: chatJid) { (try await send(), false) }
    }

    private func performSend(localId: String, chatJid: String, _ send: @Sendable () async throws -> (BridgeSendResult, Bool)) async {
        do {
            let (result, stored) = try await send()
            try await ingest.completeSend(localId: localId, chatJid: chatJid, result: result, stored: stored)
            await recovery.scheduleCheck()
        } catch {
            WAKit.log.error("send failed: \(error)")
            try? await ingest.failSend(localId: localId, chatJid: chatJid)
        }
    }

    /// The quote as the target is shown: its whole text with its mention list, so it renders the same.
    static func quote(_ item: MessageItem) -> BridgeQuoted {
        BridgeQuoted(id: item.message.id, senderJid: item.message.senderJid, kind: item.message.kind,
                     snippet: item.message.text ?? "", mentions: item.message.extra?.mentions ?? [])
    }

    // MARK: Message actions (optimistic locally, then queued in `outbox`)

    /// Toggle semantics are the caller's: pass "" to remove your reaction.
    public func react(to key: BridgeMessageKey, emoji: String) async throws {
        try await ingest.localReaction(key, emoji: emoji, senderJid: ownJid ?? "", timestamp: Self.now)
        await outbox.schedule()
    }

    /// `mentions`: the JIDs the edited text's "@<number>"s stand for.
    public func edit(_ key: BridgeMessageKey, text: String, mentions: [String] = []) async throws {
        try await ingest.localEdit(key, text: text, mentions: mentions, editedAt: Self.now)
        await outbox.schedule()
    }

    public func revoke(_ key: BridgeMessageKey) async throws {
        try await ingest.localRevoke(key, timestamp: Self.now)
        await outbox.schedule()
    }

    private static var now: Int64 { Int64(Date().timeIntervalSince1970) }

    public func sendChatState(_ state: ChatState, in chatJid: String) async {
        try? await bridge.sendChatState(chat: chatJid, state: state)
    }

    public func subscribePresence(_ jid: String) async {
        try? await bridge.subscribePresence(jid: jid)
    }

    // MARK: Chat actions (optimistic locally, then queued in `outbox`)

    public func setPinned(_ chatJid: String, _ pinned: Bool) async throws {
        try await ingest.applyLocal(.pin(chatJid: chatJid, pinnedAt: pinned ? Self.now : nil))
        await outbox.schedule()
    }

    /// `nil` unmutes; `Int64.max` mutes forever.
    public func setMuted(_ chatJid: String, until: Int64?) async throws {
        try await ingest.applyLocal(.mute(chatJid: chatJid, mutedUntil: until))
        await outbox.schedule()
    }

    public func setArchived(_ chatJid: String, _ archived: Bool) async throws {
        try await ingest.applyLocal(.archive(chatJid: chatJid, archived: archived))
        await outbox.schedule()
    }

    /// `read == false` marks the chat unread.
    public func setRead(_ chatJid: String, _ read: Bool) async throws {
        try await ingest.applyLocal(.markRead(chatJid: chatJid, read: read))
        await outbox.schedule()
    }
}

extension WaBridgeProtocol {
    /// Default for bridges that cannot decrypt (test and preview stubs): nothing opens.
    public func decryptParked(envelopes: [Data]) async -> [BridgeMessageUpdate?] {
        Array(repeating: nil, count: envelopes.count)
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
