import Testing
@testable import WAKit

@Suite struct MentionsTests {
    @Test func applyReplacesOnlyKnownMentions() {
        let names = ["99887766": "Alice", "15552220000": "Bob"]
        #expect(Mentions.apply("@99887766 @12345678 hi @15552220000", names) == "@Alice @12345678 hi @Bob")
        #expect(Mentions.apply("mail a@99887766x or @1234", names) == "mail a@99887766x or @1234")
    }

    @Test func mentionsResolveThroughLidAliases() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([
            .ownJid(pn: F.me, lid: "11112222@lid"),
            F.history(contacts: [BridgeContact(jid: F.alicePN, fullName: "Alice Example", firstName: nil, pushName: nil, phone: nil)],
                      aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)]),
            F.live(F.message("a", chat: F.group, sender: F.bob, text: "@99887766 @11112222 @15552220000 @55554444")),
        ])
        let page = try await ChatWindowLoader(database: db, chatJid: F.group).initial()
        #expect(page.items.first?.displayText == "@Alice Example @You @+15552220000 @55554444")
        #expect(page.items.first?.message.text == "@99887766 @11112222 @15552220000 @55554444")
        let mentions = page.items.first?.mentions ?? [:]
        #expect(mentions["99887766"] == Mention(name: "Alice Example", jid: F.alicePN, phone: JID.phoneDisplay(F.alicePN)))
        #expect(mentions["11112222"]?.jid == nil)
    }
}
