import Foundation
import Testing
@testable import WAKit

@Suite struct ReceiptTests {
    @Test func statusOnlyMovesForwardAndRetryIsIgnored() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(F.message("S1", chat: F.bob, fromMe: true, status: .sent))])

        try await ingest.apply([F.receipt(["S1"], chat: F.bob, kind: .delivered)])
        #expect(try db.message(F.bob, "S1")?.status == .delivered)
        try await ingest.apply([F.receipt(["S1"], chat: F.bob, kind: .retry)])
        #expect(try db.message(F.bob, "S1")?.status == .delivered)
        try await ingest.apply([F.receipt(["S1"], chat: F.bob, kind: .played)])
        #expect(try db.message(F.bob, "S1")?.status == .read)
        try await ingest.apply([F.receipt(["S1"], chat: F.bob, kind: .delivered), F.receipt(["S1"], chat: F.bob, kind: .sent)])
        #expect(try db.message(F.bob, "S1")?.status == .read)
        #expect(try db.chat(F.bob)?.lastMessageStatus == .read)
    }

    @Test func receiptBeforeMessageIsParkedThenApplied() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.receipt(["S2"], chat: F.bob, kind: .read)])
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 1)
        try await ingest.apply([F.live(F.message("S2", chat: F.bob, fromMe: true, status: .sent))])
        #expect(try db.message(F.bob, "S2")?.status == .read)
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 0)
    }
}

@Suite struct UnreadTests {
    @Test func incomingIncrementsUnlessOpenAndKey() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(F.message("2", chat: F.bob, fromMe: true, ts: 1_700_000_001), F.message("1", chat: F.bob))])
        #expect(try db.chat(F.bob)?.unreadCount == 1)

        ingest.focus.set(chatJid: F.bob, windowIsKey: false)
        try await ingest.apply([F.live(F.message("3", chat: F.bob, ts: 1_700_000_002))])
        #expect(try db.chat(F.bob)?.unreadCount == 2)

        ingest.focus.set(chatJid: F.bob, windowIsKey: true)
        try await ingest.apply([F.live(F.message("4", chat: F.bob, ts: 1_700_000_003))])
        #expect(try db.chat(F.bob)?.unreadCount == 2)

        // System messages never count.
        ingest.focus.set(chatJid: nil, windowIsKey: false)
        try await ingest.apply([F.live(F.message("5", chat: F.bob, ts: 1_700_000_004, kind: .system))])
        #expect(try db.chat(F.bob)?.unreadCount == 2)
    }

    @Test func readSelfAndMarkReadActionZeroUnread() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(F.message("1", chat: F.bob), F.message("2", chat: F.bob, ts: 1_700_000_001))])
        try await ingest.apply([F.receipt(["2"], chat: F.bob, kind: .readSelf, from: F.me)])
        #expect(try db.chat(F.bob)?.unreadCount == 0)
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 0)

        try await ingest.apply([F.live(F.message("3", chat: F.bob, ts: 1_700_000_002))])
        try await ingest.apply([.chatAction(action: .markRead(chatJid: F.bob, read: true))])
        #expect(try db.chat(F.bob)?.unreadCount == 0)
    }

    @Test func markedUnreadSurvivesIncomingAndClearsOnOpen() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(F.message("1", chat: F.group, sender: F.bob))])
        try await ingest.apply([.chatAction(action: .markRead(chatJid: F.group, read: false))])
        try await ingest.apply([F.live(F.message("2", chat: F.group, sender: F.alicePN, ts: 1_700_000_001))])
        var chat = try #require(try db.chat(F.group))
        #expect(chat.markedUnread && chat.unreadCount == 2)
        // ReadSelf zeroes the count but not the explicit mark.
        try await ingest.apply([F.receipt(["2"], chat: F.group, kind: .readSelf, from: F.me)])
        chat = try #require(try db.chat(F.group))
        #expect(chat.markedUnread && chat.unreadCount == 0)

        try await ingest.apply([F.live(F.message("3", chat: F.group, sender: F.alicePN, ts: 1_700_000_002))])
        let result = try await ingest.chatOpened(F.group)
        #expect(result.wasMarkedUnread)
        #expect(result.unreadKeys == [F.key("3", chat: F.group, participant: F.alicePN)])
        chat = try #require(try db.chat(F.group))
        #expect(!chat.markedUnread && chat.unreadCount == 0)
    }

    @MainActor @Test func clientOpenChatSendsReceipts() async throws {
        let db = try F.tempDB()
        let bridge = FakeBridge()
        let client = try WAClient(database: db) { _ in bridge }
        try await client.ingest.apply([F.live(F.message("1", chat: F.bob), F.message("2", chat: F.bob, ts: 1_700_000_001))])
        try await client.ingest.apply([.chatAction(action: .markRead(chatJid: F.bob, read: false))])
        await client.openChat(F.bob)
        let calls = bridge.calls.withLock { $0 }
        #expect(calls.markRead.count == 1)
        #expect(Set(calls.markRead[0].1.map(\.id)) == ["1", "2"])
        #expect(calls.markChatRead.first?.1 == true)
        #expect(client.focus.current.chatJid == F.bob)
    }
}
