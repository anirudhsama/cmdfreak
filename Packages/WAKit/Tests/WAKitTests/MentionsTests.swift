import Testing
@testable import WAKit

@Suite struct MentionsTests {
    @Test func applyReplacesOnlyKnownMentions() {
        let names = ["99887766": "Alice", "15552220000": "Bob"]
        #expect(Mentions.apply("@99887766 @12345678 hi @15552220000", names) == "@Alice @12345678 hi @Bob")
        #expect(Mentions.apply("mail a@99887766x or @1234", names) == "mail a@99887766x or @1234")
    }

    @Test func phoneNumbersAreGroupedLikeTheirCountry() {
        #expect(PhoneFormat.display("447700900208") == "+44 7700 900208")
        #expect(PhoneFormat.display("919876543210") == "+91 98765 43210")
        #expect(JID.phoneDisplay("14155550123@s.whatsapp.net") == "+1 415-555-0123")
        #expect(PhoneFormat.display("999") == "+999")
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
        #expect(page.items.first?.displayText == "@Alice Example @You @+1 555-222-0000 @55554444")
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

    /// Clients strip the quoted message's list: a quote without one uses the stored target's list, else guesses.
    @Test func quotesWithoutAListUseTheTargetsOrGuess() async throws {
        let (db, ingest) = try await seeded()
        let quote = { (id: String) in BridgeQuoted(id: id, senderJid: F.bob, kind: .text, snippet: "@99887766 ok", mentions: []) }
        try await ingest.apply([F.live(
            F.message("literal", chat: F.group, sender: F.bob, ts: 1, text: "@99887766 ok"),
            F.message("r1", chat: F.group, sender: F.bob, ts: 2, text: "reply", quoted: quote("literal")),
            F.message("r2", chat: F.group, sender: F.bob, ts: 3, text: "reply", quoted: quote("elsewhere"))
        )])
        let items = try await ChatWindowLoader(database: db, chatJid: F.group).initial().items
        #expect(items.first { $0.id == "r1" }?.displayQuotedSnippet == "@99887766 ok")
        #expect(items.first { $0.id == "r2" }?.displayQuotedSnippet == "@Alice Example ok")
    }

    /// The mention list travels with the text: an edit applied to a placeholder outlives the original's list,
    /// and our own edits keep the message's list.
    @Test func mentionListsFollowTheirText() async throws {
        let (db, ingest) = try await seeded()
        try await ingest.apply([F.live(F.message("p", chat: F.group, sender: F.bob, ts: 1, kind: .undecryptable, text: nil))])
        try await ingest.apply([F.live(updates: [.edit(target: F.key("p", chat: F.group, participant: F.bob), text: "hi @99887766",
                                                       mentions: [F.aliceLID], editedAt: 9)])])
        try await ingest.apply([F.live(F.message("p", chat: F.group, sender: F.bob, ts: 1, text: "@55554444", mentions: ["55554444@lid"]))])
        try await ingest.apply([F.live(F.message("m", chat: F.group, fromMe: true, ts: 2, text: "@99887766 hey", mentions: [F.aliceLID]))])
        try await ingest.localEdit(F.key("m", chat: F.group, fromMe: true), text: "@99887766 hey!", editedAt: 10)
        let items = try await ChatWindowLoader(database: db, chatJid: F.group).initial().items
        #expect(items.first { $0.id == "p" }?.displayText == "hi @Alice Example")
        #expect(items.first { $0.id == "m" }?.displayText == "@Alice Example hey!")
    }

    @Test func listedJidsLoseDeviceSuffixes() {
        #expect(Mentions.Resolver.bare("15551110000:12@s.whatsapp.net") == "15551110000@s.whatsapp.net")
        #expect(Mentions.Resolver.bare("99887766.0:3@lid") == "99887766@lid")
        #expect(Mentions.Resolver.bare("99887766@lid") == "99887766@lid")
    }

    /// Rows stored before the mentioned JIDs were kept guess each number as a LID, then a phone number.
    @Test func rowsWithoutAListGuess() async throws {
        let (db, ingest) = try await seeded()
        try await ingest.apply([F.live(F.message("a", chat: F.group, sender: F.bob, text: "@99887766 @55554444", mentions: [F.aliceLID]))])
        try await db.pool.write { try $0.execute(sql: "UPDATE message SET extra = NULL") }
        let item = try await ChatWindowLoader(database: db, chatJid: F.group).initial().items.first
        #expect(item?.displayText == "@Alice Example @55554444")
    }

    /// A sent message keeps its mention list, and its quote the target's: the quote reads like the
    /// target did on screen, even once the target is gone.
    @Test func sentMessagesAndTheirQuotesKeepTheirLists() async throws {
        let db = try F.tempDB()
        let bridge = FakeBridge()
        let client = try await WAClient(database: db) { _ in bridge }
        try await client.ingest.apply([
            .ownJid(pn: F.me, lid: "11112222@lid"),
            F.history(contacts: [BridgeContact(jid: F.alicePN, fullName: "Alice Example", firstName: nil, pushName: nil, phone: nil)],
                      aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)]),
            F.live(F.message("T", chat: F.group, sender: F.bob, text: "hey @99887766", mentions: [F.aliceLID])),
        ])
        let target = try #require(try await client.windowLoader(for: F.group).items(ids: ["T"]).first)
        try await client.sendText("@15551110000 look", mentions: [F.alicePN], to: F.group, replyTo: target)
        #expect(bridge.calls.withLock { $0.textMentions } == [[F.alicePN]])
        try await db.pool.write { try $0.execute(sql: "DELETE FROM message WHERE id = 'T'") }
        let sent = try #require(try await client.windowLoader(for: F.group).initial().items.first { $0.message.fromMe })
        #expect(sent.displayText == "@Alice Example look")
        #expect(sent.displayQuotedSnippet == "hey @Alice Example")
    }

    @Test func groupMembersAreNamedLikeTheirMentions() async throws {
        let db = try F.tempDB()
        let client = try await WAClient(database: db) { _ in FakeBridge() }
        try await client.ingest.apply([
            .ownJid(pn: F.me, lid: "11112222@lid"),
            F.history(contacts: [BridgeContact(jid: F.alicePN, fullName: "Alice Example", firstName: nil, pushName: nil, phone: nil)],
                      aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)]),
            F.live(F.message("a", chat: F.group, sender: F.bob, text: "hi")),
        ])
        let members = await client.groupMembers(F.group)
        #expect(members.map(\.name) == ["+1 555-222-0000", "Alice Example"])
        #expect(members.map(\.jid) == [F.bob, F.alicePN])
    }
}
