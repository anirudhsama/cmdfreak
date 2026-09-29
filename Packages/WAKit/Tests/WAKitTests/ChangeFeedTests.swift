import Foundation
import Testing
@testable import WAKit

@Suite struct ChangeFeedTests {
    /// Collects the next `n` changes from a subscription.
    func collect(_ stream: AsyncStream<MessageChange>, _ n: Int) async -> [MessageChange] {
        var out: [MessageChange] = []
        for await c in stream {
            out.append(c)
            if out.count == n { break }
        }
        return out
    }

    @Test func publishesAddUpdateDeleteAfterCommit() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let stream = ingest.feed.changes(for: F.bob)
        let other = ingest.feed.changes(for: F.group)
        _ = other

        try await ingest.apply([F.live(F.message("a", chat: F.bob), F.message("b", chat: F.bob, ts: 1_700_000_001))])
        try await ingest.apply([F.live(F.message("g", chat: F.group, sender: F.bob))])
        try await ingest.apply([F.live(updates: [.edit(target: F.key("a", chat: F.bob), text: "edited", editedAt: 9)])])
        try await ingest.apply([.chatAction(action: .deleteMessageForMe(target: F.key("b", chat: F.bob)))])
        try await ingest.apply([.chatAction(action: .clear(chatJid: F.bob))])

        let changes = await collect(stream, 4)
        guard case .add(let added) = changes[0] else { Issue.record("expected add"); return }
        #expect(added.map(\.id) == ["a", "b"])
        guard case .update(let updated) = changes[1] else { Issue.record("expected update"); return }
        #expect(updated.first?.message.text == "edited")
        #expect(changes[2] == .delete(ids: ["b"]))
        #expect(changes[3] == .reload)
    }

    @Test func optimisticSendReplacesLocalRow() async throws {
        let db = try F.tempDB()
        let bridge = FakeBridge()
        let client = try await WAClient(database: db) { _ in bridge }
        let stream = client.feed.changes(for: F.bob)

        let localId = try await client.sendText("hi there", to: F.bob)
        let changes = await collect(stream, 2)
        guard case .add(let added) = changes[0] else { Issue.record("expected add"); return }
        #expect(added.first?.message.status == .pending)
        #expect(added.first?.id == localId)
        guard case .replace(let old, let item) = changes[1] else { Issue.record("expected replace"); return }
        #expect(old == localId)
        // Written to the socket only; sent once the server acks it.
        #expect(item.message.status == .pending && item.id.hasPrefix("SRV-"))
        #expect(try db.count("SELECT COUNT(*) FROM message") == 1)
        #expect(try db.chat(F.bob)?.lastMessageFromMe == true)
        try await client.ingest.apply([.serverAck(ack: BridgeServerAck(chatJid: nil, messageId: item.id, error: nil))])
        #expect(try db.message(F.bob, item.id)?.status == .sent)
    }

    @Test func ackBeforeSendResultIsParkedAndNackFails() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let pending = try await ingest.insertOutgoing(chatJid: F.bob, text: "yo")
        try await ingest.apply([.serverAck(ack: BridgeServerAck(chatJid: F.bob, messageId: "SRV1", error: nil))])
        try await ingest.completeSend(localId: pending.id, chatJid: F.bob, result: BridgeSendResult(
            messageId: "SRV1", timestamp: 1_700_000_900, message: F.message("SRV1", chat: F.bob, fromMe: true, text: "yo")))
        #expect(try db.message(F.bob, "SRV1")?.status == .sent)

        let other = try await ingest.insertOutgoing(chatJid: F.bob, text: "no")
        try await ingest.completeSend(localId: other.id, chatJid: F.bob, result: BridgeSendResult(
            messageId: "SRV2", timestamp: 1_700_000_901, message: F.message("SRV2", chat: F.bob, fromMe: true, text: "no")))
        try await ingest.apply([.serverAck(ack: BridgeServerAck(chatJid: F.bob, messageId: "SRV2", error: "479"))])
        #expect(try db.message(F.bob, "SRV2")?.status == .failed)
    }

    @Test func reconnectResendsUnackedUnderTheSameIdWithItsQuote() async throws {
        let db = try F.tempDB()
        let bridge = FakeBridge()
        let client = try await WAClient(database: db) { _ in bridge }
        try await client.ingest.apply([F.live(F.message("Q", chat: F.group, sender: F.bob, text: "question"))])
        // Pending on our phone, from history: not ours to resend.
        try await client.ingest.apply([F.live(F.message("PHONE", chat: F.group, fromMe: true, text: "x", status: .pending))])
        let quoted = try #require(try await client.windowLoader(for: F.group).items(ids: ["Q"]).first)
        let localId = try await client.sendText("answer", to: F.group, replyTo: quoted)
        let sent = "SRV-\("answer".hashValue.magnitude)"
        #expect(try db.message(F.group, localId) == nil)
        #expect(try db.message(F.group, sent)?.status == .pending)

        // Nothing goes out while disconnected.
        await client.recovery.run(reconnected: true)
        #expect(bridge.calls.withLock { $0.textSends.count } == 1)
        await client.recovery.setConnected(true)
        await client.recovery.run(reconnected: true)
        let sends = bridge.calls.withLock { $0.textSends }
        #expect(sends.count == 2)
        #expect(sends.last?.messageId == sent)
        #expect(sends.last?.replyTo?.id == "Q" && sends.last?.replyTo?.participant == F.bob)
        #expect(try db.message(F.group, sent)?.status == .pending)

        // A resend that errors keeps it pending; after `maxAttempts` unacked sends it fails.
        bridge.sendFails = true
        for _ in 0..<SendRecovery.maxAttempts { await client.recovery.run(reconnected: true) }
        #expect(try db.message(F.group, sent)?.status == .failed)
        #expect(try db.message(F.group, "PHONE")?.status == .pending)

        // A manual retry keeps the id; an ack settles it.
        bridge.sendFails = false
        try await client.retry(localId: sent, chatJid: F.group)
        #expect(bridge.calls.withLock { $0.textSends.last?.messageId } == sent)
        #expect(try db.message(F.group, sent)?.status == .pending)
        try await client.ingest.apply([.serverAck(ack: BridgeServerAck(chatJid: F.group, messageId: sent, error: nil))])
        #expect(try db.message(F.group, sent)?.status == .sent)
        let before = bridge.calls.withLock { $0.textSends.count }
        await client.recovery.run(reconnected: true)
        #expect(bridge.calls.withLock { $0.textSends.count } == before)
    }

    @Test func mediaIsResentWithItsFileNeverAsItsCaption() async throws {
        let db = try F.tempDB()
        let bridge = FakeBridge()
        let client = try await WAClient(database: db) { _ in bridge }
        let file = FileManager.default.temporaryDirectory.appending(path: "resend-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8]).write(to: file)
        let outgoing = BridgeOutgoingMedia(kind: .image, filePath: file.path, mimetype: "image/jpeg", fileName: nil, caption: "look",
                                           width: nil, height: nil, durationSecs: nil, jpegThumbnail: nil,
                                           thumbnailWidth: nil, thumbnailHeight: nil, pageCount: nil)
        let pending = try await client.ingest.insertOutgoing(chatJid: F.bob, text: "look", kind: .image, media: outgoing)
        try await client.ingest.completeSend(localId: pending.id, chatJid: F.bob, result: BridgeSendResult(
            messageId: "IMG1", timestamp: Int64(Date().timeIntervalSince1970),
            message: F.message("IMG1", chat: F.bob, fromMe: true, kind: .image, text: "look")))

        await client.recovery.setConnected(true)
        await client.recovery.run(reconnected: true)
        #expect(bridge.calls.withLock { $0.mediaSends.map(\.messageId) } == ["IMG1"])
        try FileManager.default.removeItem(at: file)
        await client.recovery.run(reconnected: true)
        #expect(bridge.calls.withLock { $0.mediaSends.count } == 1)
        #expect(bridge.calls.withLock { $0.textSends.isEmpty })
    }

    @Test func acksMatchTheRightMessageAndStrayOnesAreNotKept() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        // A reaction's ack, with no send in flight: dropped.
        try await ingest.apply([.serverAck(ack: BridgeServerAck(chatJid: F.bob, messageId: "REACT", error: nil))])
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 0)

        // Beats the send result under a LID spelling of the chat: still found. An edit parked for
        // the same id in another chat stays there.
        let pending = try await ingest.insertOutgoing(chatJid: F.bob, text: "yo")
        try await ingest.apply([.serverAck(ack: BridgeServerAck(chatJid: F.aliceLID, messageId: "SRV1", error: nil))])
        try await ingest.apply([.messages(messages: [], updates: [
            .edit(target: BridgeMessageKey(chatJid: F.group, id: "SRV1", fromMe: false, participant: F.alicePN), text: "e", editedAt: 1)])])
        try await ingest.completeSend(localId: pending.id, chatJid: F.bob, result: BridgeSendResult(
            messageId: "SRV1", timestamp: 1_700_000_900, message: F.message("SRV1", chat: F.bob, fromMe: true, text: "yo")))
        #expect(try db.message(F.bob, "SRV1")?.status == .sent)
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation WHERE chatJid = ?", [F.group]) == 1)

        // Same id in two chats: the ack's chat decides.
        try await ingest.apply([F.live(F.message("DUP", chat: F.bob, fromMe: true, status: .pending),
                                       F.message("DUP", chat: F.group, fromMe: true, status: .pending))])
        try await ingest.apply([.serverAck(ack: BridgeServerAck(chatJid: F.group, messageId: "DUP", error: nil))])
        #expect(try db.message(F.group, "DUP")?.status == .sent)
        #expect(try db.message(F.bob, "DUP")?.status == .pending)
    }

    @Test func sendsInterruptedBeforeTheServerIdFailAtLaunch() async throws {
        let db = try F.tempDB()
        let pending = try await IngestActor(database: db).insertOutgoing(chatJid: F.bob, text: "lost")
        _ = try IngestActor(database: db)
        #expect(try db.message(F.bob, pending.id)?.status == .failed)
    }

    @Test func awaitingAckIsNotPendingForActions() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let pending = try await ingest.insertOutgoing(chatJid: F.bob, text: "yo")
        #expect(pending.message.isPending)
        try await ingest.completeSend(localId: pending.id, chatJid: F.bob, result: BridgeSendResult(
            messageId: "SRV1", timestamp: 1_700_000_900, message: F.message("SRV1", chat: F.bob, fromMe: true, text: "yo")))
        let sent = try #require(try db.message(F.bob, "SRV1"))
        #expect(sent.status == .pending && !sent.isPending)
    }

    @Test func receiptBeforeSendResultStillApplies() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let pending = try await ingest.insertOutgoing(chatJid: F.bob, text: "yo")
        try await ingest.apply([F.receipt(["SRV1"], chat: F.bob, kind: .delivered)])
        try await ingest.completeSend(localId: pending.id, chatJid: F.bob, result: BridgeSendResult(
            messageId: "SRV1", timestamp: 1_700_000_900, message: F.message("SRV1", chat: F.bob, fromMe: true, text: "yo")))
        #expect(try db.message(F.bob, "SRV1")?.status == .delivered)
        #expect(try db.message(F.bob, pending.id) == nil)
    }

    @Test func failedSendIsMarkedAndRetried() async throws {
        let db = try F.tempDB()
        let bridge = FakeBridge()
        bridge.sendFails = true
        let client = try await WAClient(database: db) { _ in bridge }
        let localId = try await client.sendText("nope", to: F.bob)
        #expect(try db.message(F.bob, localId)?.status == .failed)
        bridge.sendFails = false
        try await client.retry(localId: localId, chatJid: F.bob)
        #expect(try db.message(F.bob, localId) == nil)
        #expect(try db.count("SELECT COUNT(*) FROM message WHERE fromMe = 1 AND id LIKE 'SRV-%'") == 1)
    }

    @Test func eventSinkHopsBatchesIntoIngest() async throws {
        let db = try F.tempDB()
        let bridge = FakeBridge()
        nonisolated(unsafe) var sink: (any EventSink)?
        let client = try await WAClient(database: db) { s in sink = s; return bridge }
        _ = sink?.onEvents(events: [F.live(F.message("via-sink", chat: F.bob))])
        for _ in 0..<200 where try db.message(F.bob, "via-sink") == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try db.message(F.bob, "via-sink") != nil)
        _ = client
    }
}
