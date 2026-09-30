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

    @Test func dmReceiptCoversEarlierSentMessages() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(
            F.message("P", chat: F.bob, fromMe: true, ts: 1_700_000_000, status: .pending),
            F.message("A", chat: F.bob, fromMe: true, ts: 1_700_000_001, status: .sent),
            F.message("B", chat: F.bob, fromMe: true, ts: 1_700_000_002, status: .sent),
            F.message("C", chat: F.bob, fromMe: true, ts: 1_700_000_003, status: .sent))])

        try await ingest.apply([F.receipt(["B"], chat: F.bob, kind: .read)])
        #expect(try db.message(F.bob, "A")?.status == .read)
        #expect(try db.message(F.bob, "B")?.status == .read)
        #expect(try db.message(F.bob, "C")?.status == .sent)
        #expect(try db.message(F.bob, "P")?.status == .pending)
    }

    @Test func groupMessageAdvancesOnceEveryRecipientHasReachedIt() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([.group(group: BridgeGroup(jid: F.group, subject: "G", participantCount: 3, participants: []))])
        try await ingest.apply([F.live(F.message("G1", chat: F.group, fromMe: true, ts: 1_700_000_001, status: .sent))])
        // Someone joining later doesn't hold back a message sent before.
        try await ingest.apply([.group(group: BridgeGroup(jid: F.group, subject: nil, participantCount: 4, participants: []))])

        try await ingest.apply([F.receipt(["G1"], chat: F.group, kind: .read, from: F.bob)])
        #expect(try db.message(F.group, "G1")?.status == .sent)
        // Readers are counted once each; a reader's LID receipts fold into their phone-number JID.
        try await ingest.apply([F.receipt(["G1"], chat: F.group, kind: .delivered, from: F.aliceLID)])
        #expect(try db.message(F.group, "G1")?.status == .delivered)
        try await ingest.apply([.jidAliases(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)])])
        #expect(try db.count("SELECT COUNT(*) FROM receipt WHERE readerJid = ?", [F.aliceLID]) == 0)
        try await ingest.apply([F.receipt(["G1"], chat: F.group, kind: .delivered, from: F.bob)])
        #expect(try db.message(F.group, "G1")?.status == .delivered)
        try await ingest.apply([F.receipt(["G1"], chat: F.group, kind: .read, from: F.alicePN)])
        #expect(try db.message(F.group, "G1")?.status == .read)
    }

    @Test func groupReceiptCoversTheReadersEarlierMessages() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([.group(group: BridgeGroup(jid: F.group, subject: "G", participantCount: 2, participants: []))])
        try await ingest.apply([F.live(
            F.message("G0", chat: F.group, fromMe: true, ts: 1_700_000_000, status: .sent),
            F.message("G1", chat: F.group, fromMe: true, ts: 1_700_000_001, status: .sent),
            F.message("G2", chat: F.group, fromMe: true, ts: 1_700_000_002, status: .sent),
            F.message("G3", chat: F.group, fromMe: true, ts: 1_700_000_003, status: .sent))])

        try await ingest.apply([F.receipt(["G1"], chat: F.group, kind: .delivered, from: F.bob)])
        try await ingest.apply([F.receipt(["G3"], chat: F.group, kind: .read, from: F.bob)])
        // Back to the reader's first receipt here, not before it.
        #expect(try db.message(F.group, "G0")?.status == .sent)
        #expect(try db.message(F.group, "G1")?.status == .read)
        #expect(try db.message(F.group, "G2")?.status == .read)
        #expect(try db.message(F.group, "G3")?.status == .read)
    }

    @Test func parkedGroupReceiptWaitsForTheGroupSize() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.receipt(["G1"], chat: F.group, kind: .read, from: F.bob)])
        try await ingest.apply([F.live(F.message("G1", chat: F.group, fromMe: true, status: .sent))])
        #expect(try db.message(F.group, "G1")?.status == .sent)
        try await ingest.apply([.group(group: BridgeGroup(jid: F.group, subject: "G", participantCount: 2, participants: []))])
        #expect(try db.message(F.group, "G1")?.status == .read)
    }

    @Test func groupReceiptsSkipUnsentMessagesOwnReadersAndArriveInAnyOrder() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([.ownJid(pn: F.me, lid: nil)])
        try await ingest.apply([.group(group: BridgeGroup(jid: F.group, subject: "G", participantCount: 2, participants: []))])
        try await ingest.apply([F.live(
            F.message("G1", chat: F.group, fromMe: true, ts: 1_700_000_001, status: .sent),
            F.message("G2", chat: F.group, fromMe: true, ts: 1_700_000_002, status: .sent),
            F.message("G3", chat: F.group, fromMe: true, ts: 1_700_000_003, status: .sent),
            F.message("G4", chat: F.group, fromMe: true, ts: 1_700_000_004, status: .sent))])
        let failed = try await ingest.insertOutgoing(chatJid: F.group, text: "x")
        try await ingest.failSend(localId: failed.id, chatJid: F.group)

        try await ingest.apply([F.receipt(["G1"], chat: F.group, kind: .read, from: F.me)])
        #expect(try db.message(F.group, "G1")?.status == .sent)

        // Bob's read of G3 lands before his delivery of G1: G2 is covered either way.
        try await ingest.apply([F.receipt(["G3"], chat: F.group, kind: .read, from: F.bob)])
        try await ingest.apply([F.receipt(["G1"], chat: F.group, kind: .delivered, from: F.bob)])
        #expect(try db.message(F.group, "G1")?.status == .read)
        #expect(try db.message(F.group, "G2")?.status == .read)
        #expect(try db.message(F.group, "G4")?.status == .sent)

        // The failed send between G4 and G5 is left alone.
        try await ingest.apply([F.receipt(["G4"], chat: F.group, kind: .delivered, from: F.bob)])
        try await ingest.apply([F.live(F.message("G5", chat: F.group, fromMe: true, ts: 4_000_000_000, status: .sent))])
        try await ingest.apply([F.receipt(["G5"], chat: F.group, kind: .read, from: F.bob)])
        #expect(try db.message(F.group, "G4")?.status == .read)
        #expect(try db.message(F.group, failed.id)?.status == .failed)
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

    @Test func readOnAnotherDeviceCoversMessagesDeliveredLater() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        // Offline delivery: the phone's read-self receipt lands before a message it lists.
        try await ingest.apply([F.live(F.message("1", chat: F.bob))])
        try await ingest.apply([F.receipt(["1", "2"], chat: F.bob, kind: .readSelf, from: F.me)])
        var result = try await ingest.applyBatch([F.live(F.message("2", chat: F.bob, ts: 1_700_000_050))])
        #expect(try db.chat(F.bob)?.unreadCount == 0)
        #expect(result.notices.isEmpty)
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 0)
        // Older than the receipt but not listed: the phone had not seen it.
        try await ingest.apply([F.live(F.message("3", chat: F.bob, ts: 1_700_000_040))])
        #expect(try db.chat(F.bob)?.unreadCount == 1)

        // The mark-read action covers its synced range, even before the chat exists here.
        try await ingest.apply([.chatAction(action: .markRead(chatJid: F.alicePN, read: true, readThrough: 1_700_000_300))])
        try await ingest.apply([F.live(F.message("4", chat: F.alicePN, ts: 1_700_000_250))])
        #expect(try db.chat(F.alicePN)?.unreadCount == 0)
        try await ingest.apply([F.live(F.message("5", chat: F.alicePN, ts: 1_700_000_400))])
        #expect(try db.chat(F.alicePN)?.unreadCount == 1)
        // Without a range (e.g. the echo of our own mark-read) nothing later is covered.
        try await ingest.apply([.chatAction(action: .markRead(chatJid: F.bob, read: true, readThrough: nil))])
        try await ingest.apply([F.live(F.message("6", chat: F.bob, ts: 1_700_000_010))])
        #expect(try db.chat(F.bob)?.unreadCount == 1)

        // A placeholder read elsewhere stays silent when its content lands after newer unread.
        try await ingest.apply([F.receipt(["7"], chat: F.bob, kind: .readSelf, from: F.me)])
        try await ingest.apply([F.live(F.message("7", chat: F.bob, ts: 1_700_000_500, kind: .undecryptable, text: nil))])
        try await ingest.apply([F.live(F.message("8", chat: F.bob, ts: 1_700_000_600))])
        result = try await ingest.applyBatch([F.live(F.message("7", chat: F.bob, ts: 1_700_000_500))])
        #expect(!result.notices.contains { if case .incoming(let n) = $0 { n.messageId == "7" } else { false } })
        #expect(try db.chat(F.bob)?.unreadCount == 2)  // 6 (not listed) and 8
    }

    @Test func remoteReadsCoverOnlyWhatTheyRead() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        func unread() throws -> Set<String> {
            try db.pool.read { try Set(String.fetchAll($0, sql: "SELECT id FROM message WHERE chatJid = ? AND unread", arguments: [F.bob])) }
        }
        // A newer message that lands before a delayed read-self receipt stays unread.
        try await ingest.apply([F.live(F.message("1", chat: F.bob, ts: 100), F.message("2", chat: F.bob, ts: 200))])
        var result = try await ingest.applyBatch([F.receipt(["1"], chat: F.bob, kind: .readSelf, from: F.me)])
        #expect(try unread() == ["2"])
        #expect(try db.chat(F.bob)?.unreadCount == 1)
        #expect(result.notices == [.messageRemoved(chatJid: F.bob, messageId: "1")])

        // A placeholder read elsewhere, then an older unlisted message: only the latter is unread,
        // the placeholder's content does not alert, and opening sends a receipt for the latter.
        try await ingest.apply([F.receipt(["P"], chat: F.bob, kind: .readSelf, from: F.me)])
        try await ingest.apply([F.live(F.message("P", chat: F.bob, ts: 400, kind: .undecryptable, text: nil),
                                       F.message("U", chat: F.bob, ts: 350))])
        result = try await ingest.applyBatch([F.live(F.message("P", chat: F.bob, ts: 400))])
        #expect(!result.notices.contains { if case .incoming = $0 { true } else { false } })
        #expect(try unread() == ["2", "U"])
        let opened = try await ingest.chatOpened(F.bob)
        #expect(Set(opened.unreadKeys.map(\.id)) == ["2", "U"])
        #expect(try db.chat(F.bob)?.unreadCount == 0)

        // The echo of a mark-read spares what arrived after it was done.
        try await ingest.apply([F.live(F.message("3", chat: F.bob, ts: 500), F.message("4", chat: F.bob, ts: 700))])
        try await ingest.apply([.chatAction(action: .markRead(chatJid: F.bob, read: true, readThrough: nil, readAt: 600))])
        #expect(try unread() == ["4"])

        // A read-self receipt addressed to the LID reads the message stored under the PN once the
        // alias is known.
        try await ingest.apply([F.live(F.message("A", chat: F.alicePN, ts: 100))])
        try await ingest.apply([F.receipt(["A"], chat: F.aliceLID, kind: .readSelf, from: F.me)])
        #expect(try db.chat(F.alicePN)?.unreadCount == 1)
        try await ingest.apply([.jidAliases(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)])])
        #expect(try db.chat(F.alicePN)?.unreadCount == 0)
    }

    @Test func snapshotCountWithoutMessagesStaysUntilRead() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.history(chats: [F.chat(F.bob, unread: 3)], messages: [F.message("1", chat: F.bob, ts: 100)])])
        #expect(try db.chat(F.bob)?.unreadCount == 3)
        try await ingest.apply([F.live(F.message("2", chat: F.bob, ts: 200))])
        #expect(try db.chat(F.bob)?.unreadCount == 4)
        // The phone read the chat through 2: the snapshot's unread predate it.
        try await ingest.apply([F.receipt(["2"], chat: F.bob, kind: .readSelf, from: F.me)])
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
