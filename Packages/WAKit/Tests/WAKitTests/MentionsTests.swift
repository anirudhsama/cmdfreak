import Testing
@testable import WAKit

@Suite struct MentionsTests {
    @Test func applyReplacesOnlyKnownMentions() {
        let names = ["99887766": "Alice", "15552220000": "Bob"]
        #expect(Mentions.apply("@99887766 @12345678 hi @15552220000", names) == "@Alice @12345678 hi @Bob")
        #expect(Mentions.apply("mail a@99887766x or @1234", names) == "mail a@99887766x or @1234")
    }

    private func seeded() async throws -> (AppDatabase, IngestActor) {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([
            .ownJid(pn: F.me, lid: "11112222@lid"),
            F.history(contacts: [BridgeContact(jid: F.alicePN, fullName: "Alice Example", firstName: nil, pushName: nil, phone: nil)],
                      aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)]),
        ])
        return (db, ingest)
    }

    @Test func mentionsResolveThroughLidAliases() async throws {
        let (db, ingest) = try await seeded()
        try await ingest.apply([F.live(F.message("a", chat: F.group, sender: F.bob, text: "@99887766 @11112222 @15552220000 @55554444",
                                                 mentions: [F.aliceLID, "11112222@lid", F.bob, "55554444@lid"]))])
        let page = try await ChatWindowLoader(database: db, chatJid: F.group).initial()
        #expect(page.items.first?.displayText == "@Alice Example @You @+15552220000 @55554444")
        #expect(page.items.first?.message.text == "@99887766 @11112222 @15552220000 @55554444")
        let mentions = page.items.first?.mentions ?? [:]
        #expect(mentions["99887766"] == Mention(name: "Alice Example", jid: F.alicePN, phone: JID.phoneDisplay(F.alicePN)))
        #expect(mentions["11112222"]?.jid == nil)
    }

    /// Only numbers the message lists as mentioned count; the list says which user each number is.
    @Test func onlyListedJidsAreMentions() async throws {
        let (db, ingest) = try await seeded()
        try await ingest.apply([F.live(
            F.message("a", chat: F.group, sender: F.bob, text: "@99887766 call @15551110000",
                      mentions: [F.aliceLID],
                      quoted: BridgeQuoted(id: "q", senderJid: F.bob, kind: .text, snippet: "@15551110000 ok", mentions: [F.alicePN])),
            F.message("b", chat: F.group, sender: F.bob, text: "no one @99887766")
        )])
        let items = try await ChatWindowLoader(database: db, chatJid: F.group).initial().items
        let a = try #require(items.first { $0.id == "a" })
        #expect(a.displayText == "@Alice Example call @15551110000")
        #expect(a.displayQuotedSnippet == "@Alice Example ok")
        #expect(a.quotedMentions["15551110000"]?.jid == F.alicePN)
        #expect(items.first { $0.id == "b" }?.displayText == "no one @99887766")
    }

    @Test func editsReplaceTheMentions() async throws {
        let (db, ingest) = try await seeded()
        try await ingest.apply([F.live(F.message("a", chat: F.group, sender: F.bob, text: "hi"))])
        try await ingest.apply([F.live(updates: [.edit(target: F.key("a", chat: F.group, participant: F.bob), text: "hi @99887766",
                                                       mentions: [F.aliceLID], editedAt: 9)])])
        let item = try await ChatWindowLoader(database: db, chatJid: F.group).initial().items.first
        #expect(item?.displayText == "hi @Alice Example")
    }

    /// Rows stored before the mentioned JIDs were kept guess each number as a LID, then a phone number.
    @Test func rowsWithoutAListGuess() async throws {
        let (db, ingest) = try await seeded()
        try await ingest.apply([F.live(F.message("a", chat: F.group, sender: F.bob, text: "@99887766 @55554444", mentions: [F.aliceLID]))])
        try await db.pool.write { try $0.execute(sql: "UPDATE message SET extra = NULL") }
        let item = try await ChatWindowLoader(database: db, chatJid: F.group).initial().items.first
        #expect(item?.displayText == "@Alice Example @55554444")
    }
}
