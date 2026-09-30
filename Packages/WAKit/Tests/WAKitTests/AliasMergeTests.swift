import Foundation
import Testing
@testable import WAKit

@Suite struct AliasMergeTests {
    @Test func lidChatRenamedToPhoneNumberWhenNoDuplicate() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([
            F.live(F.message("L1", chat: F.aliceLID, kind: .image, media: F.media()),
                   updates: [.reaction(target: F.key("L1", chat: F.aliceLID),
                                       reaction: BridgeReaction(senderJid: F.aliceLID, fromMe: false, emoji: "❤️", timestamp: 1))]),
            .contacts(contacts: [BridgeContact(jid: F.aliceLID, fullName: nil, firstName: nil, pushName: "Ali", phone: nil)]),
        ])
        try await ingest.apply([.jidAliases(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)])])

        #expect(try db.chat(F.aliceLID) == nil)
        let chat = try #require(try db.chat(F.alicePN))
        #expect(chat.unreadCount == 1)
        let item = try #require(try await ChatWindowLoader(database: db, chatJid: F.alicePN).initial().items.first)
        #expect(item.message.senderJid == F.alicePN)
        #expect(item.media != nil)
        #expect(item.reactions.first?.senderJid == F.alicePN)
        #expect(try await db.reader.read { try ContactRecord.fetchOne($0, key: F.alicePN) }?.pushName == "Ali")
        #expect(try await db.reader.read { try ContactRecord.fetchOne($0, key: F.aliceLID) } == nil)

        // Later traffic addressed by LID lands in the PN chat.
        try await ingest.apply([F.live(F.message("L2", chat: F.aliceLID, ts: 1_700_000_050))])
        #expect(try db.chat(F.aliceLID) == nil)
        #expect(try db.chat(F.alicePN)?.lastMessageId == "L2")
    }

    @Test func duplicatedChatsMergeIntoPhoneNumber() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([
            F.live(F.message("P1", chat: F.alicePN, ts: 100), F.message("SAME", chat: F.alicePN, ts: 150)),
            F.live(F.message("L1", chat: F.aliceLID, ts: 200), F.message("SAME", chat: F.aliceLID, ts: 150)),
            .chatAction(action: .pin(chatJid: F.aliceLID, pinnedAt: 42)),
        ])
        #expect(try db.count("SELECT COUNT(*) FROM chat") == 2)

        try await ingest.apply([F.history(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)])])

        #expect(try db.count("SELECT COUNT(*) FROM chat") == 1)
        let chat = try #require(try db.chat(F.alicePN))
        #expect(chat.unreadCount == 3)  // P1, SAME, L1: the duplicate counts once
        #expect(chat.pinnedAt == 42)
        #expect(chat.lastMessageId == "L1")
        let ids = try await ChatWindowLoader(database: db, chatJid: F.alicePN).initial().items.map(\.id)
        #expect(ids == ["P1", "SAME", "L1"])
        #expect(try db.count("SELECT COUNT(*) FROM message WHERE chatJid = ?", [F.aliceLID]) == 0)
    }

    @Test func mergeDropsUnreadTheReadBoundaryCovers() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        // The PN chat is read through 100 and holds a read message at 200.
        try await ingest.apply([
            F.live(F.message("X", chat: F.alicePN, ts: 200)),
            .chatAction(action: .markRead(chatJid: F.alicePN, read: true, readThrough: 100)),
            F.live(F.message("OLD", chat: F.aliceLID, ts: 50), F.message("NEW", chat: F.aliceLID, ts: 300)),
        ])
        try await ingest.apply([F.history(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)])])
        #expect(try db.chat(F.alicePN)?.unreadCount == 1)  // NEW only
    }

    @Test func duplicatesKeepStateFromTheLidCopy() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let poll = BridgePoll(question: "Q", options: ["A", "B"], selectableCount: 1)
        try await ingest.apply([
            F.live(F.message("S", chat: F.alicePN, fromMe: true, status: .sent),
                   F.message("R", chat: F.alicePN, kind: .image, media: F.media()), F.message("E", chat: F.alicePN), F.message("P", chat: F.alicePN, kind: .poll, text: nil, poll: poll),
                   updates: [.reaction(target: F.key("E", chat: F.alicePN),
                                       reaction: BridgeReaction(senderJid: F.alicePN, fromMe: false, emoji: "😀", timestamp: 1))]),
            F.live(F.message("S", chat: F.aliceLID, fromMe: true, status: .read),
                   F.message("R", chat: F.aliceLID, kind: .image, media: F.media()), F.message("E", chat: F.aliceLID), F.message("P", chat: F.aliceLID, kind: .poll, text: nil, poll: poll),
                   updates: [
                       .revoke(target: F.key("R", chat: F.aliceLID), revokedBy: F.aliceLID, timestamp: 5),
                       .edit(target: F.key("E", chat: F.aliceLID), text: "edited", mentions: [], editedAt: 9),
                       .reaction(target: F.key("E", chat: F.aliceLID),
                                 reaction: BridgeReaction(senderJid: F.me, fromMe: true, emoji: "👍", timestamp: 2)),
                       .pollVote(target: F.key("P", chat: F.aliceLID), voterJid: F.me, selected: ["B"], timestamp: 3),
                   ]),
        ])
        try await ingest.apply([.jidAliases(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)])])

        let r = try #require(try db.message(F.alicePN, "R"))
        #expect(r.revoked && r.text == nil)
        #expect(try db.count("SELECT COUNT(*) FROM media WHERE messageId = 'R'") == 0)
        let e = try #require(try db.message(F.alicePN, "E"))
        #expect(e.text == "edited" && e.editedAt == 9)
        #expect(try db.message(F.alicePN, "S")?.status == .read)
        #expect(try db.count("SELECT COUNT(*) FROM reaction WHERE chatJid = ? AND messageId = 'E'", [F.alicePN]) == 2)
        #expect(try db.count("SELECT COUNT(*) FROM poll_vote WHERE chatJid = ? AND messageId = 'P'", [F.alicePN]) == 1)
        #expect(try db.chat(F.alicePN)?.unreadCount == 3)  // R, E, P once each
        #expect(try db.count("SELECT COUNT(*) FROM message") == 4)
    }

    @Test func groupSendersRewrittenAndAliasPersisted() async throws {
        let db = try F.tempDB()
        do {
            let ingest = try IngestActor(database: db)
            try await ingest.apply([
                F.live(F.message("G1", chat: F.group, sender: F.aliceLID)),
                .jidAliases(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)]),
            ])
            #expect(try db.message(F.group, "G1")?.senderJid == F.alicePN)
            #expect(try db.message(F.group, "G1")?.participant == F.aliceLID)  // raw, for rebuilding keys
        }
        // A fresh actor loads aliases from disk.
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(F.message("G2", chat: F.group, sender: F.aliceLID))])
        #expect(try db.message(F.group, "G2")?.senderJid == F.alicePN)
    }

    @Test func parkedMutationsFollowMergedMessages() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        // Revoke addressed to the PN chat arrives while the message still lives under the LID.
        try await ingest.apply([
            F.live(F.message("X", chat: F.aliceLID)),
            F.live(updates: [.revoke(target: F.key("X", chat: F.alicePN), revokedBy: F.alicePN, timestamp: 5)]),
        ])
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 1)
        try await ingest.apply([.jidAliases(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)])])
        #expect(try db.message(F.alicePN, "X")?.revoked == true)
        #expect(try db.count("SELECT COUNT(*) FROM pending_mutation") == 0)
    }
}
