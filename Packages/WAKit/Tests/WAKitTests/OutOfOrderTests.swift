import Foundation
import Testing
@testable import WAKit

@Suite struct OutOfOrderTests {
    @Test func revokeBeforeOriginal() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.history(updates: [.revoke(target: F.key("R1", chat: F.bob), revokedBy: F.bob, timestamp: 10)])])
        #expect(try db.message(F.bob, "R1") == nil)
        try await ingest.apply([F.history(messages: [F.message("R1", chat: F.bob, kind: .image, text: "secret", media: F.media())])])
        let m = try #require(try db.message(F.bob, "R1"))
        #expect(m.revoked && m.text == nil)
        #expect(try db.count("SELECT COUNT(*) FROM media") == 0)
        #expect(try db.count("SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH 'secret'") == 0)
        #expect(try db.chat(F.bob)?.lastMessageRevoked == true)
    }

    @Test func editBeforeOriginalAndStaleEditIgnored() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(updates: [.edit(target: F.key("E1", chat: F.bob), text: "fixed", editedAt: 200)])])
        try await ingest.apply([F.live(F.message("E1", chat: F.bob, text: "typo"))])
        var m = try #require(try db.message(F.bob, "E1"))
        #expect(m.text == "fixed" && m.editedAt == 200)
        #expect(try db.chat(F.bob)?.lastMessageText == "fixed")

        try await ingest.apply([F.live(updates: [.edit(target: F.key("E1", chat: F.bob), text: "older", editedAt: 150)])])
        m = try #require(try db.message(F.bob, "E1"))
        #expect(m.text == "fixed")
        #expect(try db.count("SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH 'fixed'") == 1)
        #expect(try db.count("SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH 'typo'") == 0)
    }

    @Test func reactionsAndPollVotesBeforeOriginal() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let target = F.key("P1", chat: F.group, participant: F.bob)
        try await ingest.apply([F.live(updates: [
            .reaction(target: target, reaction: BridgeReaction(senderJid: F.alicePN, fromMe: false, emoji: "😂", timestamp: 5)),
            .reaction(target: target, reaction: BridgeReaction(senderJid: F.me, fromMe: true, emoji: "👍", timestamp: 5)),
            .reaction(target: target, reaction: BridgeReaction(senderJid: F.me, fromMe: true, emoji: "", timestamp: 6)),
            .pollVote(target: target, voterJid: F.alicePN, selected: ["Yes"], timestamp: 7),
        ])])
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 4)
        try await ingest.apply([F.live(F.message("P1", chat: F.group, sender: F.bob, kind: .poll, text: nil,
                                                 poll: BridgePoll(question: "Lunch?", options: ["Yes", "No"], selectableCount: 1)))])
        let item = try #require(try await ChatWindowLoader(database: db, chatJid: F.group).initial().items.first)
        #expect(item.reactions.map(\.emoji) == ["😂"])
        #expect(item.pollVotes.map(\.selected) == [["Yes"]])
        #expect(item.message.extra?.poll?.options == ["Yes", "No"])
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 0)
    }

    @Test func mutationsWithinOneBatchBeforeTheirTarget() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        // Same batch: updates are applied after the batch's messages, but a later chunk may still precede.
        try await ingest.apply([
            F.history(updates: [.edit(target: F.key("B1", chat: F.bob), text: "v2", editedAt: 9)]),
            F.history(messages: [F.message("B1", chat: F.bob, text: "v1")]),
        ])
        #expect(try db.message(F.bob, "B1")?.text == "v2")
    }

    @Test func deleteForMeBeforeTheMessageKeepsItDeleted() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([.chatAction(action: .deleteMessageForMe(target: F.key("D1", chat: F.bob)))])
        try await ingest.apply([F.live(F.message("D1", chat: F.bob))])
        #expect(try db.message(F.bob, "D1") == nil)
        #expect(try db.chat(F.bob)?.unreadCount == 0)
        // Deleted after it arrived, then a stale history copy: still gone, also after a restart.
        try await ingest.apply([F.live(F.message("D2", chat: F.bob))])
        try await ingest.apply([.chatAction(action: .deleteMessageForMe(target: F.key("D2", chat: F.bob)))])
        let restarted = try IngestActor(database: db)
        try await restarted.apply([F.history(messages: [F.message("D2", chat: F.bob), F.message("D3", chat: F.bob)])])
        #expect(try db.message(F.bob, "D2") == nil)
        #expect(try db.message(F.bob, "D3") != nil)
    }

    @Test func reactionAndVoteRemovalsOutliveStaleCopiesButNotNewerOnes() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let removal = BridgeReaction(senderJid: F.alicePN, fromMe: false, emoji: "", timestamp: 20)
        try await ingest.apply([F.live(updates: [
            .reaction(target: F.key("G", chat: F.group), reaction: removal),
            .pollVote(target: F.key("P", chat: F.group), voterJid: F.alicePN, selected: [], timestamp: 20),
        ])])
        // The target arrives from history carrying the older reaction inline, plus the older vote.
        let old = BridgeReaction(senderJid: F.alicePN, fromMe: false, emoji: "🔥", timestamp: 10)
        let poll = BridgePoll(question: "Lunch?", options: ["Yes", "No"], selectableCount: 1)
        try await ingest.apply([F.history(
            messages: [F.message("G", chat: F.group, sender: F.bob, reactions: [old]),
                       F.message("P", chat: F.group, sender: F.bob, kind: .poll, text: nil, poll: poll)],
            updates: [.pollVote(target: F.key("P", chat: F.group), voterJid: F.alicePN, selected: ["Yes"], timestamp: 10)])])
        #expect(try db.count("SELECT COUNT(*) FROM reaction") == 0)
        #expect(try db.count("SELECT COUNT(*) FROM poll_vote") == 0)
        // Another stale copy later still does not resurrect them.
        try await ingest.apply([F.history(messages: [F.message("G", chat: F.group, sender: F.bob, reactions: [old])])])
        try await ingest.apply([F.live(updates: [.reaction(target: F.key("G", chat: F.group), reaction: old)])])
        #expect(try db.count("SELECT COUNT(*) FROM reaction") == 0)
        // A genuinely newer reaction and vote win over the older removal.
        let newer = BridgeReaction(senderJid: F.alicePN, fromMe: false, emoji: "❤️", timestamp: 30)
        try await ingest.apply([F.live(updates: [
            .reaction(target: F.key("G", chat: F.group), reaction: newer),
            .pollVote(target: F.key("P", chat: F.group), voterJid: F.alicePN, selected: ["No"], timestamp: 30),
        ])])
        #expect(try db.count("SELECT COUNT(*) FROM reaction WHERE emoji = '❤️'") == 1)
        #expect(try db.count("SELECT COUNT(*) FROM poll_vote WHERE selected = '[\"No\"]'") == 1)
    }

    @Test func removalTombstonesFollowAliasMerges() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(updates: [.reaction(target: F.key("M", chat: F.aliceLID),
            reaction: BridgeReaction(senderJid: F.aliceLID, fromMe: false, emoji: "", timestamp: 20))])])
        try await ingest.apply([.jidAliases(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)])])
        try await ingest.apply([F.history(messages: [F.message("M", chat: F.alicePN, reactions: [
            BridgeReaction(senderJid: F.alicePN, fromMe: false, emoji: "🔥", timestamp: 10)])])])
        #expect(try db.count("SELECT COUNT(*) FROM reaction") == 0)
    }

    @Test func unknownTimestampsAndOwnClockSkewDoNotSuppressReactions() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(F.message("M", chat: F.group, sender: F.bob))])
        // Our removal stamped by this Mac at 1000; our re-reaction from the phone, whose clock is 20s behind.
        try await ingest.apply([F.live(updates: [.reaction(target: F.key("M", chat: F.group),
            reaction: BridgeReaction(senderJid: F.me, fromMe: true, emoji: "", timestamp: 1000))])])
        try await ingest.apply([F.live(updates: [.reaction(target: F.key("M", chat: F.group),
            reaction: BridgeReaction(senderJid: F.me, fromMe: true, emoji: "👍", timestamp: 980))])])
        #expect(try db.count("SELECT COUNT(*) FROM reaction WHERE senderJid = ?", [F.me]) == 1)
        // Someone else's removal, then a history copy of their reaction without a timestamp: kept.
        try await ingest.apply([F.live(F.message("N", chat: F.group, sender: F.bob))])
        try await ingest.apply([F.live(updates: [.reaction(target: F.key("N", chat: F.group),
            reaction: BridgeReaction(senderJid: F.alicePN, fromMe: false, emoji: "", timestamp: 1000))])])
        try await ingest.apply([F.history(messages: [F.message("N", chat: F.group, sender: F.bob, reactions: [
            BridgeReaction(senderJid: F.alicePN, fromMe: false, emoji: "🔥", timestamp: 0)])])])
        #expect(try db.count("SELECT COUNT(*) FROM reaction WHERE messageId = 'N'") == 1)
    }

    @Test func aliasMergeKeepsTheNewestRemovalTime() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let remove = { (sender: String, ts: Int64) in
            F.live(updates: [.reaction(target: F.key("M", chat: F.group), reaction: BridgeReaction(senderJid: sender, fromMe: false, emoji: "", timestamp: ts))])
        }
        // Newer removal under the PN, older under the LID (not yet known to be the same person).
        try await ingest.apply([remove(F.alicePN, 50), remove(F.aliceLID, 20)])
        try await ingest.apply([.jidAliases(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)])])
        #expect(try db.count("SELECT COUNT(*) FROM tombstone") == 1)
        #expect(try db.count("SELECT COUNT(*) FROM tombstone WHERE senderJid = ? AND timestamp = 50", [F.alicePN]) == 1)
        try await ingest.apply([F.history(messages: [F.message("M", chat: F.group, sender: F.bob, reactions: [
            BridgeReaction(senderJid: F.alicePN, fromMe: false, emoji: "🔥", timestamp: 30)])])])
        #expect(try db.count("SELECT COUNT(*) FROM reaction") == 0)
    }

    @Test func nothingParksForADeletedMessageAndOldRemovalsArePruned() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([.chatAction(action: .deleteMessageForMe(target: F.key("D", chat: F.bob)))])
        try await ingest.apply([F.live(updates: [.edit(target: F.key("D", chat: F.bob), text: "x", editedAt: 5)])])
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 0)
        // Parked before the delete and still there when the (deleted) message shows up: dropped then.
        try await ingest.apply([F.live(updates: [.edit(target: F.key("E", chat: F.bob), text: "x", editedAt: 5)])])
        try await db.pool.write { db in
            try db.execute(sql: "INSERT INTO tombstone (chatJid, messageId, kind, senderJid, timestamp) VALUES (?, 'E', 'message', '', 0)",
                           arguments: [F.bob])
        }
        let restarted = try IngestActor(database: db)
        try await restarted.apply([F.live(F.message("E", chat: F.bob))])
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 0)
        // Reaction/vote removals expire; delete-for-me tombstones stay.
        try await restarted.apply([F.live(updates: [.reaction(target: F.key("R", chat: F.bob),
            reaction: BridgeReaction(senderJid: F.bob, fromMe: false, emoji: "", timestamp: 100))])])
        try await restarted.pruneTombstones(olderThan: 1_000)
        #expect(try db.count("SELECT COUNT(*) FROM tombstone WHERE kind = 'reaction'") == 0)
        #expect(try db.count("SELECT COUNT(*) FROM tombstone WHERE kind = 'message'") == 2)
    }
}
