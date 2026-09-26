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
}
