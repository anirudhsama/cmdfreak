import Foundation
import Testing
@testable import WAKit

@Suite struct IngestMappingTests {
    @Test func mapsMessageMediaQuotedReactionsAndExtras() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let quoted = BridgeQuoted(id: "Q1", senderJid: F.bob, kind: .text, snippet: "earlier")
        let reaction = BridgeReaction(senderJid: F.bob, fromMe: false, emoji: "👍", timestamp: 1_700_000_010)
        try await ingest.apply([
            F.live(
                F.message("M1", chat: F.group, sender: F.alicePN, kind: .image, text: "caption here",
                          media: F.media(), quoted: quoted, reactions: [reaction], pushName: "Alice"),
                F.message("M2", chat: F.group, sender: F.bob, ts: 1_700_000_001, kind: .location, text: nil,
                          location: BridgeLocation(latitude: 1, longitude: 2, name: "Cafe", address: nil, isLive: false))
            ),
        ])

        let page = try await ChatWindowLoader(database: db, chatJid: F.group).initial()
        #expect(page.items.map(\.id) == ["M1", "M2"])
        let m1 = page.items[0]
        #expect(m1.message.kind == .image)
        #expect(m1.message.text == "caption here")
        #expect(m1.message.quotedId == "Q1" && m1.message.quotedSnippet == "earlier")
        #expect(m1.message.participant == F.alicePN)
        #expect(m1.media?.fileSha256 == Data(repeating: 1, count: 32))
        #expect(m1.media?.bridgeMedia == F.media())
        #expect(m1.reactions.map(\.emoji) == ["👍"])
        #expect(m1.senderName == "Alice")
        #expect(page.items[1].message.extra?.location?.name == "Cafe")

        let chat = try #require(try db.chat(F.group))
        #expect(chat.kind == .group)
        #expect(chat.lastMessageId == "M2")
        #expect(chat.lastMessageKind == .location)
        #expect(chat.lastActivityAt == 1_700_000_001)
        #expect(chat.unreadCount == 2)

        // Push name recorded as a contact; FTS populated from the caption.
        #expect(try await db.reader.read { try ContactRecord.fetchOne($0, key: F.alicePN) }?.pushName == "Alice")
        #expect(try db.count("SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH 'caption'") == 1)
    }

    @Test func redeliveryDoesNotDuplicateOrRecountUnread() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let m = F.message("M1", chat: F.bob)
        try await ingest.apply([F.live(m)])
        try await ingest.apply([F.live(m), F.history(messages: [m])])
        #expect(try db.count("SELECT COUNT(*) FROM message") == 1)
        #expect(try db.chat(F.bob)?.unreadCount == 1)
    }

    @Test func historyChunkWritesChatsContactsMessagesWithoutUnreadBumps() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.history(
            chats: [F.chat(F.bob, unread: 3, pinnedAt: 1_600_000_000), F.chat(F.group, name: "Team")],
            messages: (0..<10).map { F.message("H\($0)", chat: F.bob, ts: 1_600_000_000 + Int64($0)) },
            contacts: [BridgeContact(jid: F.bob, fullName: "Bob Builder", firstName: "Bob", pushName: nil, phone: "15552220000")],
            type: .initialBootstrap
        )])
        let bob = try #require(try db.chat(F.bob))
        #expect(bob.unreadCount == 3)
        #expect(bob.pinnedAt == 1_600_000_000)
        #expect(bob.lastMessageId == "H9")

        let items = try await db.reader.read { try ChatListQuery.fetch($0, filter: .chats) }
        #expect(items.map(\.id) == [F.bob, F.group])  // pinned first
        #expect(items[0].title == "Bob Builder")
        #expect(items[1].title == "Team")
    }

    @Test func chatListFilterAndOrdering() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let c1 = "1@s.whatsapp.net", c2 = "2@s.whatsapp.net", c3 = "3@s.whatsapp.net"
        try await ingest.apply([
            F.live(F.message("a", chat: c1, ts: 100), F.message("b", chat: c2, ts: 300), F.message("c", chat: c3, ts: 200)),
            .chatAction(action: .archive(chatJid: c2, archived: true)),
            .chatAction(action: .pin(chatJid: c1, pinnedAt: 5)),
        ])
        let chats = try await db.reader.read { try ChatListQuery.fetch($0, filter: RailItem.chats.filter()) }
        #expect(chats.map(\.id) == [c1, c3])
        let archived = try await db.reader.read { try ChatListQuery.fetch($0, filter: RailItem.archived.filter()) }
        #expect(archived.map(\.id) == [c2])

        // Tags: include and exclude.
        try await db.pool.write { db in
            var tag = TagRecord(id: nil, name: "Work", color: nil, sortOrder: 0)
            try tag.insert(db)
            try ChatTagRecord(chatJid: c3, tagId: tag.id!).insert(db)
        }
        let tagged = try await db.reader.read { try ChatListQuery.fetch($0, filter: RailItem.tag(id: 1, name: "Work").filter()) }
        #expect(tagged.map(\.id) == [c3])
        let hidden = try await db.reader.read { try ChatListQuery.fetch($0, filter: RailItem.chats.filter(hiddenTags: [1])) }
        #expect(hidden.map(\.id) == [c1])
    }

    @MainActor @Test func chatListObservationDeliversImmediately() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(F.message("a", chat: F.bob))])
        var received: [[ChatListItem]] = []
        let cancellable = db.observeChatList(filter: .chats) { received.append($0) }
        #expect(received.count == 1)  // synchronous first value
        #expect(received[0].first?.preview?.messageId == "a")
        try await ingest.apply([F.live(F.message("b", chat: F.bob, ts: 1_700_000_100))])
        for _ in 0..<100 where received.last?.first?.preview?.messageId != "b" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(received.last?.first?.preview?.messageId == "b")
        cancellable.cancel()
    }

    @Test func sortKeyOrdersByTimestampThenIngestOrder() async throws {
        #expect(SortKey.make(timestamp: 10, seq: 99) < SortKey.make(timestamp: 11, seq: 1))
        #expect(SortKey.make(timestamp: 10, seq: 1) < SortKey.make(timestamp: 10, seq: 2))
        #expect(SortKey.timestamp(of: SortKey.make(timestamp: 1_700_000_000, seq: 12345)) == 1_700_000_000)

        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        // History typically arrives newest-first; order must follow timestamps.
        try await ingest.apply([F.history(messages: [
            F.message("new", chat: F.bob, ts: 300), F.message("mid", chat: F.bob, ts: 200), F.message("old", chat: F.bob, ts: 100),
        ])])
        let page = try await ChatWindowLoader(database: db, chatJid: F.bob).initial()
        #expect(page.items.map(\.id) == ["old", "mid", "new"])
    }

    @Test func windowLoaderPaging() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.history(messages: (0..<100).map { F.message("m\($0)", chat: F.bob, ts: 1000 + Int64($0)) })])
        let loader = ChatWindowLoader(database: db, chatJid: F.bob)

        let first = try await loader.initial(limit: 30)
        #expect(first.items.map(\.id) == (70..<100).map { "m\($0)" })
        #expect(first.hasOlder && !first.hasNewer)

        let older = try await loader.older(before: first.oldestSortKey!, limit: 30)
        #expect(older.items.map(\.id) == (40..<70).map { "m\($0)" })
        #expect(older.hasOlder)

        let oldest = try await loader.older(before: older.oldestSortKey!, limit: 50)
        #expect(oldest.items.count == 40 && !oldest.hasOlder)

        let newer = try await loader.newer(after: older.newestSortKey!, limit: 10)
        #expect(newer.items.map(\.id) == (70..<80).map { "m\($0)" })
        #expect(newer.hasNewer)

        let around = try #require(try await loader.around(messageId: "m50", limit: 10))
        #expect(around.items.map(\.id) == (45..<55).map { "m\($0)" })
        #expect(around.hasOlder && around.hasNewer)
        #expect(try await loader.around(messageId: "nope") == nil)
    }

    @Test func chatActions() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(F.message("a", chat: F.bob), F.message("b", chat: F.bob, ts: 1_700_000_001))])
        try await ingest.apply([
            .chatAction(action: .mute(chatJid: F.bob, mutedUntil: Int64.max)),
            .chatAction(action: .deleteMessageForMe(target: F.key("b", chat: F.bob))),
        ])
        var bob = try #require(try db.chat(F.bob))
        #expect(bob.isMuted())
        #expect(bob.lastMessageId == "a")

        try await ingest.apply([.chatAction(action: .clear(chatJid: F.bob))])
        bob = try #require(try db.chat(F.bob))
        #expect(bob.lastMessageId == nil && bob.unreadCount == 0)
        #expect(try db.count("SELECT COUNT(*) FROM message") == 0)
        #expect(try db.count("SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH 'hello'") == 0)

        try await ingest.apply([.chatAction(action: .delete(chatJid: F.bob))])
        #expect(try db.chat(F.bob) == nil)
    }

    @Test func groupsFillNamesAndParticipants() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let bridge = FakeBridge()
        let jids = (0..<120).map { "12036300000\($0)@g.us" }
        try await ingest.apply([F.live(F.message("g1", chat: F.group, sender: F.bob))] +
                               jids.map { F.live(F.message("x", chat: $0, sender: F.bob)) })
        let groups = GroupService(bridge: bridge, ingest: ingest)
        await groups.fillMissingNames()
        #expect(bridge.calls.withLock { $0.overviews.map(\.count) } == [50, 50, 21])
        #expect(try db.count("SELECT COUNT(*) FROM chat WHERE kind = 'group' AND name IS NULL") == 0)

        try await groups.loadMetadata(jid: F.group)
        #expect(try db.count("SELECT COUNT(*) FROM group_participant WHERE groupJid = ?", [F.group]) == 2)
    }
}
