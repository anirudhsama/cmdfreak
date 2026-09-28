import Foundation
import Testing
@testable import WAKit

/// Re-deliveries, chat snapshots and actions that must reconcile with state already stored.
@Suite struct ReconcileTests {
    @Test func realMessageUpgradesUndecryptablePlaceholder() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([
            F.live(F.message("U", chat: F.bob, kind: .undecryptable, text: nil),
                   updates: [.reaction(target: F.key("U", chat: F.bob),
                                       reaction: BridgeReaction(senderJid: F.me, fromMe: true, emoji: "👍", timestamp: 5))]),
        ])
        let before = try #require(try db.message(F.bob, "U"))
        let stream = ingest.feed.changes(for: F.bob)

        let quoted = BridgeQuoted(id: "Q", senderJid: F.me, kind: .text, snippet: "earlier")
        try await ingest.apply([F.live(F.message("U", chat: F.bob, kind: .image, text: "sunset caption",
                                                 media: F.media(), quoted: quoted, pushName: "Bob"))])

        let after = try #require(try db.message(F.bob, "U"))
        #expect(after.kind == .image && after.text == "sunset caption" && after.quotedId == "Q" && after.pushName == "Bob")
        #expect(after.sortKey == before.sortKey)
        #expect(try db.count("SELECT COUNT(*) FROM media WHERE chatJid = ? AND messageId = 'U'", [F.bob]) == 1)
        #expect(try db.count("SELECT COUNT(*) FROM reaction WHERE messageId = 'U'") == 1)
        #expect(try db.count("SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH 'sunset'") == 1)
        let chat = try #require(try db.chat(F.bob))
        #expect(chat.lastMessageKind == .image && chat.lastMessageText == "sunset caption")
        #expect(chat.unreadCount == 1)  // counted once, when the placeholder arrived
        for await change in stream {
            #expect(change.ids == ["U"])
            guard case .update(let items) = change else { Issue.record("expected update, got \(change)"); break }
            #expect(items.first?.message.kind == .image)
            break
        }

        // History CIPHERTEXT stub that was revoked meanwhile: stays revoked, takes no media.
        try await ingest.apply([
            F.history(messages: [F.message("C", chat: F.bob, kind: .undecryptable, text: nil)]),
            F.live(updates: [.revoke(target: F.key("C", chat: F.bob), revokedBy: F.bob, timestamp: 9)]),
            F.history(messages: [F.message("C", chat: F.bob, kind: .image, text: "secret", media: F.media(sha: 3))]),
        ])
        let c = try #require(try db.message(F.bob, "C"))
        #expect(c.kind == .image && c.revoked && c.text == nil)
        #expect(try db.count("SELECT COUNT(*) FROM media WHERE messageId = 'C'") == 0)
    }

    @Test func historyRevokeStubDropsMediaOfExistingRow() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(F.message("M", chat: F.bob, kind: .image, media: F.media()))])
        try await ingest.apply([F.history(messages: [F.message("M", chat: F.bob, text: nil, revoked: true)])])
        #expect(try db.message(F.bob, "M")?.revoked == true)
        #expect(try db.count("SELECT COUNT(*) FROM media WHERE messageId = 'M'") == 0)
        // A later history copy of the original body does not bring the media back.
        try await ingest.apply([F.history(messages: [F.message("M", chat: F.bob, kind: .image, media: F.media())])])
        #expect(try db.count("SELECT COUNT(*) FROM media WHERE messageId = 'M'") == 0)
    }

    @Test func historySnapshotDoesNotReapplyStaleChatState() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let snapshot = F.chat(F.bob, name: "Bob", lastActivity: 100, unread: 3, pinnedAt: 42, archived: true, markedUnread: true)
        try await ingest.apply([F.history(chats: [snapshot])])
        try await ingest.applyLocal(.pin(chatJid: F.bob, pinnedAt: nil))
        try await ingest.applyLocal(.archive(chatJid: F.bob, archived: false))
        try await ingest.applyLocal(.markRead(chatJid: F.bob, read: true))

        try await ingest.apply([F.history(chats: [F.chat(F.bob, name: "Bobby", lastActivity: 200, unread: 3, pinnedAt: 42,
                                                         archived: true, markedUnread: true)])])
        let chat = try #require(try db.chat(F.bob))
        #expect(chat.pinnedAt == nil && !chat.archived && !chat.markedUnread && chat.unreadCount == 0)
        #expect(chat.name == "Bobby" && chat.lastActivityAt == 200)

        // A chat that live traffic created before its first snapshot still gets the snapshot's state.
        try await ingest.apply([F.live(F.message("1", chat: F.alicePN))])
        try await ingest.apply([F.history(chats: [F.chat(F.alicePN, unread: 4, pinnedAt: 7, archived: true)])])
        let alice = try #require(try db.chat(F.alicePN))
        #expect(alice.pinnedAt == 7 && alice.archived && alice.unreadCount == 4)
    }

    @Test func clearAndDeleteKeepMessagesNewerThanCutoff() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(F.message("a", chat: F.bob, ts: 100), F.message("b", chat: F.bob, ts: 200),
                                       F.message("c", chat: F.bob, ts: 300))])
        let stream = ingest.feed.changes(for: F.bob)
        try await ingest.apply([.chatAction(action: .clear(chatJid: F.bob, cutoff: 200))])
        for await change in stream { #expect(change == .reload); break }
        #expect(try db.count("SELECT COUNT(*) FROM message WHERE chatJid = ?", [F.bob]) == 1)
        var chat = try #require(try db.chat(F.bob))
        #expect(chat.lastMessageId == "c" && chat.unreadCount == 1)

        try await ingest.apply([F.live(F.message("d", chat: F.bob, ts: 400))])
        try await ingest.apply([.chatAction(action: .delete(chatJid: F.bob, cutoff: 300))])
        chat = try #require(try db.chat(F.bob))
        #expect(chat.lastMessageId == "d")
        #expect(try db.count("SELECT COUNT(*) FROM message WHERE chatJid = ?", [F.bob]) == 1)

        try await ingest.apply([.chatAction(action: .delete(chatJid: F.bob, cutoff: 400))])
        #expect(try db.chat(F.bob) == nil)
    }

    @Test func parkedReactionsAndVotesUseAliasLearnedLater() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let poll = BridgePoll(question: "Lunch?", options: ["Yes", "No"], selectableCount: 1)
        try await ingest.apply([F.live(updates: [
            .reaction(target: F.key("G", chat: F.group), reaction: BridgeReaction(senderJid: F.aliceLID, fromMe: false, emoji: "🔥", timestamp: 3)),
            .pollVote(target: F.key("P", chat: F.group), voterJid: F.aliceLID, selected: ["No"], timestamp: 4),
        ])])
        try await ingest.apply([.jidAliases(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)])])
        try await ingest.apply([F.live(F.message("G", chat: F.group, sender: F.bob),
                                       F.message("P", chat: F.group, sender: F.bob, kind: .poll, text: nil, poll: poll))])
        #expect(try db.count("SELECT COUNT(*) FROM reaction WHERE senderJid = ?", [F.alicePN]) == 1)
        #expect(try db.count("SELECT COUNT(*) FROM poll_vote WHERE voterJid = ?", [F.alicePN]) == 1)
        #expect(try db.count("SELECT COUNT(*) FROM reaction WHERE senderJid = ?", [F.aliceLID]) == 0)
    }

    @Test func hashedPollVotesResolveToOptionNames() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let poll = BridgePoll(question: "Lunch?", options: ["Yes", "No"], selectableCount: 2)
        let noHash = IngestActor.sha256Hex("No")
        #expect(noHash == "1ea442a134b2a184bd5d40104401f2a37fbc09ccf3f4bc9da161c6099be3691d")
        // Parked before the poll arrives, then a live vote on the stored poll.
        try await ingest.apply([F.live(updates: [.pollVote(target: F.key("P", chat: F.group), voterJid: F.bob, selected: [noHash], timestamp: 4)])])
        try await ingest.apply([F.history(messages: [F.message("P", chat: F.group, sender: F.alicePN, kind: .poll, text: nil, poll: poll)])])
        try await ingest.apply([F.live(updates: [.pollVote(target: F.key("P", chat: F.group), voterJid: F.alicePN,
                                                           selected: [IngestActor.sha256Hex("Yes"), "No", noHash.uppercased()], timestamp: 5)])])
        let votes = try await db.reader.read {
            try Row.fetchAll($0, sql: "SELECT voterJid, selected FROM poll_vote ORDER BY voterJid").map { [$0["voterJid"] as String: $0["selected"] as String] }
        }
        #expect(votes == [[F.alicePN: #"["Yes","No","\#(noHash.uppercased())"]"#], [F.bob: #"["No"]"#]])
    }

    @Test func rolledBackTransactionRestoresInMemoryAliases() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(F.message("P", chat: F.group, sender: F.bob))])
        try await db.pool.write {
            try $0.execute(sql: "CREATE TRIGGER boom BEFORE INSERT ON poll_vote BEGIN SELECT RAISE(ABORT, 'boom'); END")
        }
        await #expect(throws: (any Error).self) {
            try await ingest.apply([
                .jidAliases(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)]),
                F.live(updates: [.pollVote(target: F.key("P", chat: F.group), voterJid: F.bob, selected: ["x"], timestamp: 1)]),
            ])
        }
        #expect(await ingest.canonicalJid(F.aliceLID) == F.aliceLID)
        #expect(try db.count("SELECT COUNT(*) FROM jid_alias") == 0)
        try await db.pool.write { try $0.execute(sql: "DROP TRIGGER boom") }
        // The alias arriving again is applied, not skipped as already known.
        try await ingest.apply([.jidAliases(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)])])
        #expect(await ingest.canonicalJid(F.aliceLID) == F.alicePN)
    }
}

/// `WAClient` wiring: durability of sink batches, receipts for the focused chat, logout.
@Suite struct ClientDurabilityTests {
    private func makeClient(_ db: AppDatabase, _ bridge: FakeBridge) async throws -> (WAClient, any EventSink) {
        nonisolated(unsafe) var sink: (any EventSink)?
        let client = try await WAClient(database: db) { s in sink = s; return bridge }
        return (client, try #require(sink))
    }

    /// Calls the sink the way the bridge does: from a plain thread that may block.
    @discardableResult
    private func deliver(_ sink: any EventSink, _ events: [BridgeEvent]) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            Thread.detachNewThread {
                c.resume(returning: sink.onEvents(events: events))
            }
        }
    }

    @Test func onEventsReportsAFailedSaveSoTheBridgeDoesNotAck() async throws {
        let db = try F.tempDB()
        let (client, sink) = try await makeClient(db, FakeBridge())
        try await db.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER boom BEFORE INSERT ON message WHEN NEW.id = 'boom' BEGIN SELECT RAISE(ABORT, 'boom'); END")
        }
        #expect(await deliver(sink, [F.live(F.message("ok", chat: F.bob))]))
        #expect(await deliver(sink, [F.live(F.message("boom", chat: F.bob), F.message("fine", chat: F.bob))]) == false)
        // The whole batch rolled back; nothing half-applied.
        #expect(try db.message(F.bob, "fine") == nil)
        // Session-only batches never fail.
        #expect(await deliver(sink, [.connection(state: .connected)]))
        _ = client
    }

    @Test func parkedEncryptedVoteIsDecryptedOnceThePollArrives() async throws {
        let db = try F.tempDB()
        let bridge = FakeBridge()
        let target = F.key("P", chat: F.bob, fromMe: true)
        bridge.parkedResult = .pollVote(target: target, voterJid: F.bob, selected: ["Yes"], timestamp: 1_700_000_010)
        let (client, sink) = try await makeClient(db, bridge)
        await deliver(sink, [F.live(updates: [.encrypted(target: target, envelope: Data([1, 2, 3]))])])
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 1)
        let poll = BridgePoll(question: "Lunch?", options: ["Yes", "No"], selectableCount: 1)
        await deliver(sink, [F.live(F.message("P", chat: F.bob, fromMe: true, kind: .poll, text: nil, poll: poll))])
        for _ in 0..<200 where try db.count("SELECT COUNT(*) FROM poll_vote") == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(bridge.calls.withLock { $0.decryptParked } == [[Data([1, 2, 3])]])
        #expect(try db.count("SELECT COUNT(*) FROM poll_vote WHERE voterJid = ? AND selected = '[\"Yes\"]'", [F.bob]) == 1)
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 0)
        _ = client
    }

    @Test func onEventsReturnsOnlyAfterCommit() async throws {
        let db = try F.tempDB()
        let (client, sink) = try await makeClient(db, FakeBridge())
        for i in 0..<20 {
            await deliver(sink, [F.live(F.message("m\(i)", chat: F.bob, ts: 1_700_000_000 + Int64(i)))])
            #expect(try db.message(F.bob, "m\(i)") != nil)
        }
        await deliver(sink, [F.history(messages: [F.message("h", chat: F.alicePN)])])
        #expect(try db.message(F.alicePN, "h") != nil)
        _ = client
    }

    @Test func incomingInFocusedChatIsMarkedRead() async throws {
        let db = try F.tempDB()
        let bridge = FakeBridge()
        let (client, sink) = try await makeClient(db, bridge)
        client.setFocus(chatJid: F.group, windowIsKey: true)
        await deliver(sink, [F.live(F.message("g1", chat: F.group, sender: F.bob), F.message("mine", chat: F.group, fromMe: true))])
        await deliver(sink, [F.live(F.message("g2", chat: F.group, sender: F.alicePN), F.message("b1", chat: F.bob))])
        #expect(try db.chat(F.group)?.unreadCount == 0)
        #expect(try db.chat(F.bob)?.unreadCount == 1)
        for _ in 0..<200 where bridge.calls.withLock({ $0.markRead.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        let calls = bridge.calls.withLock { $0.markRead }
        #expect(calls.count == 1)  // both batches coalesced into one receipt call
        #expect(calls.first?.0 == F.group)
        #expect(calls.first?.1.map(\.id) == ["g1", "g2"])
        #expect(calls.first?.1.map(\.participant) == [F.bob, F.alicePN])
    }

    @MainActor @Test func logoutForgetsOwnIdentity() async throws {
        let db = try F.tempDB()
        let bridge = FakeBridge()
        let client = try WAClient(database: db) { _ in bridge }
        try await client.ingest.apply([.ownJid(pn: F.me, lid: "1234@lid")])
        let identity = "SELECT COUNT(*) FROM meta WHERE key IN ('ownPn', 'ownLid')"
        #expect(try db.count(identity) == 2)
        try await client.logout()
        #expect(try db.count(identity) == 0)
        #expect(client.ownJid == nil)
        let ownPn = try await db.reader.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'ownPn'") }
        #expect(SessionService(bridge: nil, ownJid: ownPn).state == .unpaired)

        // A logout reported by the server (phone unlinked us) does the same.
        try await client.ingest.apply([.ownJid(pn: F.me, lid: nil), .pairing(state: .loggedOut(reason: "401"))])
        #expect(try db.count(identity) == 0)
    }

@Suite struct ParkedRetrierTests {
    @Test func sweepRetriesParkedAddOnsTheFirstTryMissedAndStopsAfterTheBound() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let bridge = FakeBridge()
        let target = F.key("P", chat: F.bob, fromMe: true)
        let poll = BridgePoll(question: "Lunch?", options: ["Yes", "No"], selectableCount: 1)
        try await ingest.apply([F.live(updates: [.encrypted(target: target, envelope: Data([1]))])])
        try await ingest.apply([F.live(F.message("P", chat: F.bob, fromMe: true, kind: .poll, text: nil, poll: poll))])
        let retrier = ParkedRetrier(ingest: ingest, bridge: bridge, delay: .milliseconds(10))
        // The secret was not in the library's store yet: nothing opens, the row stays parked.
        await retrier.sweep()
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 1)
        // A later sweep (after a connect or the post-ingest delay) opens it.
        bridge.parkedResult = .pollVote(target: target, voterJid: F.bob, selected: ["No"], timestamp: 1_700_000_010)
        await retrier.scheduleSweep()
        for _ in 0..<200 where try db.count("SELECT COUNT(*) FROM poll_vote") == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try db.count("SELECT COUNT(*) FROM poll_vote") == 1)
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 0)

        // One that never opens is tried a bounded number of times, then left for the prune.
        bridge.parkedResult = nil
        try await ingest.apply([F.live(updates: [.encrypted(target: target, envelope: Data([2]))])])
        for _ in 0..<(ParkedRetrier.maxAttempts + 3) { await retrier.sweep() }
        #expect(bridge.calls.withLock { $0.decryptParked.filter { $0 == [Data([2])] }.count } == ParkedRetrier.maxAttempts)
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 1)
    }
}
}
