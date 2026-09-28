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
        #expect(item.message.status == .sent && item.id.hasPrefix("SRV-"))
        #expect(try db.count("SELECT COUNT(*) FROM message") == 1)
        #expect(try db.chat(F.bob)?.lastMessageFromMe == true)
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
        #expect(try db.count("SELECT COUNT(*) FROM message WHERE status = ?", [MessageStatus.sent.rank]) == 1)
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
