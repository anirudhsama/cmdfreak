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
        #expect(!result.notices.contains { if case .incoming = $0 { true } else { false } })
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
        #expect(try db.chat(F.bob)?.unreadCount == 1)  // 8: reading 7 read 6 before it
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

        // A placeholder read elsewhere arrives read, and reads what came before it (2); an older
        // unlisted message after it stays unread, the placeholder's content does not alert, and
        // opening sends a receipt for exactly that message.
        try await ingest.apply([F.receipt(["P"], chat: F.bob, kind: .readSelf, from: F.me)])
        try await ingest.apply([F.live(F.message("P", chat: F.bob, ts: 400, kind: .undecryptable, text: nil))])
        try await ingest.apply([F.live(F.message("U", chat: F.bob, ts: 350))])
        result = try await ingest.applyBatch([F.live(F.message("P", chat: F.bob, ts: 400))])
        #expect(!result.notices.contains { if case .incoming = $0 { true } else { false } })
        #expect(try unread() == ["U"])
        let opened = try await ingest.chatOpened(F.bob)
        #expect(opened.unreadKeys.map(\.id) == ["U"])
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

    @Test func readSelfListingAStanzaReadsWhatWasSentBeforeIt() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        func unread(_ chat: String) throws -> Set<String> {
            try db.pool.read { try Set(String.fetchAll($0, sql: "SELECT id FROM message WHERE chatJid = ? AND unread", arguments: [chat])) }
        }
        func stanza(_ id: String, chat: String = F.group, at ts: Int64) -> BridgeEvent {
            F.live(stanzas: [BridgeStanza(chatJid: chat, id: id, timestamp: ts)])
        }
        // The phone lists an edit's own id, not the message it changed. Sent in the same second or
        // after it stays unread.
        try await ingest.apply([F.live(F.message("1", chat: F.group, sender: F.bob, ts: 100))])
        try await ingest.apply([stanza("E1", at: 200)])
        try await ingest.apply([F.live(F.message("2", chat: F.group, sender: F.bob, ts: 200),
                                       F.message("3", chat: F.group, sender: F.bob, ts: 300))])
        try await ingest.apply([F.receipt(["E1"], chat: F.group, kind: .readSelf, from: F.me)])
        #expect(try unread(F.group) == ["2", "3"])
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 0)

        // The read can land before the stanza; what was sent before it arrives read even when late.
        try await ingest.apply([F.receipt(["R1"], chat: F.group, kind: .readSelf, from: F.me)])
        try await ingest.apply([stanza("R1", at: 400)])
        #expect(try unread(F.group).isEmpty)
        try await ingest.apply([F.live(F.message("4", chat: F.group, sender: F.bob, ts: 350),
                                       F.message("5", chat: F.group, sender: F.bob, ts: 450))])
        #expect(try unread(F.group) == ["5"])
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 0)

        // Parked under the LID, recorded under the phone number: resolved once the alias is known.
        try await ingest.apply([F.live(F.message("A", chat: F.alicePN, ts: 100))])
        try await ingest.apply([stanza("X", chat: F.alicePN, at: 200)])
        try await ingest.apply([F.receipt(["X"], chat: F.aliceLID, kind: .readSelf, from: F.me)])
        #expect(try db.chat(F.alicePN)?.unreadCount == 1)
        try await ingest.apply([.jidAliases(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)])])
        #expect(try db.chat(F.alicePN)?.unreadCount == 0)
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 0)
    }

    @Test func snapshotCountWithoutMessagesStaysUntilRead() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        // The stored message is attributed and flagged; two stay unattributed.
        try await ingest.apply([F.history(chats: [F.chat(F.bob, unread: 3)], messages: [F.message("1", chat: F.bob, ts: 100)])])
        #expect(try db.chat(F.bob)?.unreadCount == 3)
        #expect(try db.count("SELECT COUNT(*) FROM message WHERE unread") == 1)
        try await ingest.apply([F.live(F.message("2", chat: F.bob, ts: 200))])
        #expect(try db.chat(F.bob)?.unreadCount == 4)
        // A clear older than the snapshot keeps the unattributed count.
        try await ingest.apply([.chatAction(action: .clear(chatJid: F.bob, cutoff: 150))])
        #expect(try db.chat(F.bob)?.unreadCount == 3)
        // The phone read the chat after the snapshot (receipt time 1_700_000_100): all read.
        try await ingest.apply([F.receipt(["2"], chat: F.bob, kind: .readSelf, from: F.me)])
        #expect(try db.chat(F.bob)?.unreadCount == 0)

        // A read that predates the snapshot's newest activity leaves its unattributed count.
        try await ingest.apply([F.history(chats: [F.chat(F.alicePN, lastActivity: 1_700_000_500, unread: 2)])])
        try await ingest.apply([F.receipt([], chat: F.alicePN, kind: .readSelf, from: F.me)])
        #expect(try db.chat(F.alicePN)?.unreadCount == 2)
        // The same snapshot under the LID merges without counting it twice.
        try await ingest.apply([F.history(chats: [F.chat(F.aliceLID, lastActivity: 1_700_000_500, unread: 2)])])
        try await ingest.apply([.jidAliases(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)])])
        #expect(try db.chat(F.alicePN)?.unreadCount == 2)
    }

    @Test func placeholderUnreadInHistoryAlertsWhenDecrypted() async throws {
        let ingest = try IngestActor(database: F.tempDB())
        let now = Int64(Date().timeIntervalSince1970)
        try await ingest.apply([F.history(chats: [F.chat(F.bob, lastActivity: now, unread: 1)],
                                          messages: [F.message("P", chat: F.bob, ts: now, kind: .undecryptable, text: nil)])])
        let result = try await ingest.applyBatch([F.live(F.message("P", chat: F.bob, ts: now))])
        #expect(result.notices.contains { if case .incoming(let n) = $0 { n.messageId == "P" } else { false } })
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

    @Test func clientMarkReadSendsReceipts() async throws {
        let db = try F.tempDB()
        let bridge = FakeBridge()
        let (client, _) = try await makeClient(db, bridge)
        try await client.ingest.apply([F.live(F.message("1", chat: F.bob), F.message("2", chat: F.bob, ts: 1_700_000_001))])
        try await client.setRead(F.bob, true)
        try await waitFor { bridge.calls.withLock { !$0.markRead.isEmpty } }
        let calls = bridge.calls.withLock { $0 }
        #expect(Set(calls.markRead.flatMap { $0.1.map(\.id) }) == ["1", "2"])
        #expect(try #require(try db.chat(F.bob)).unreadCount == 0)
    }
}
