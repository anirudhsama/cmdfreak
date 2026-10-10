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

    @Test func dmHoldingOnlyNoticesIsUnlistedUntilARealMessage() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        func notice(_ id: String, chat: String, type: String) -> BridgeMessage {
            var m = F.message(id, chat: chat, fromMe: true, ts: 1_600_000_000, kind: .system, text: nil)
            m.typeName = type
            return m
        }
        let carol = "15553330000@s.whatsapp.net"
        let listed = { try await db.reader.read { try ChatListQuery.fetch($0, filter: .chats).map(\.id) } }
        try await ingest.apply([F.history(
            chats: [F.chat(F.alicePN), F.chat(F.bob), F.chat(F.me, pinnedAt: 1_600_000_000),
                    F.chat(carol, lastActivity: 1_700_000_200, unread: 2)],
            messages: [notice("E1", chat: F.alicePN, type: "e2e_encrypted"), notice("E2", chat: F.alicePN, type: "biz_privacy_mode_to_fb"),
                       notice("E3", chat: F.bob, type: "e2e_encrypted"), F.message("B1", chat: F.bob, ts: 1_600_000_001),
                       notice("E4", chat: F.me, type: "e2e_encrypted"), notice("E5", chat: carol, type: "e2e_encrypted")]
        )])
        #expect(try await listed() == [F.me, carol, F.bob])  // pinned stays; unread messages not yet synced keep carol

        // A later snapshot of the same chat does not list it again.
        try await ingest.apply([F.history(chats: [F.chat(F.alicePN, lastActivity: 1_700_000_500)])])
        #expect(try await listed() == [F.me, carol, F.bob])

        try await ingest.apply([.chatAction(action: .pin(chatJid: F.me, pinnedAt: nil))])
        #expect(try await listed() == [carol, F.bob])

        try await ingest.apply([F.live(F.message("A1", chat: F.alicePN, ts: 1_700_001_000))])
        #expect(try await listed() == [F.alicePN, carol, F.bob])
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

    @Test func businessChatsLeaveChatsForBusinesses() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(F.message("a", chat: F.bob, ts: 100), F.message("b", chat: F.aliceLID, ts: 200, verifiedName: "Acme Ltd"),
                                       F.message("c", chat: F.group, sender: F.alicePN, ts: 300))])
        // Every DM partner and sender has a contact row, named or not.
        #expect(try db.count("SELECT COUNT(*) FROM contact WHERE jid IN ('\(F.bob)', '\(F.aliceLID)', '\(F.alicePN)')") == 3)

        // A message with a verified name marks its sender a business before any check.
        let early = try await db.reader.read { try ChatListQuery.fetch($0, filter: RailItem.businesses.filter()) }
        #expect(early.map(\.id) == [F.aliceLID])

        try await ingest.setBusiness([BridgeBusinessCheck(jid: F.aliceLID, isBusiness: true, verifiedName: nil),
                                      BridgeBusinessCheck(jid: F.bob, isBusiness: false, verifiedName: nil)], checkedAt: 1)
        // The verified name from the message survives a check without one; both follow the contact
        // through a LID → PN merge.
        try await ingest.apply([.jidAliases(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)])])

        let chats = try await db.reader.read { try ChatListQuery.fetch($0, filter: RailItem.chats.filter()) }
        #expect(chats.map(\.id) == [F.group, F.bob])
        let businesses = try await db.reader.read { try ChatListQuery.fetch($0, filter: RailItem.businesses.filter()) }
        #expect(businesses.map(\.id) == [F.alicePN])
        #expect(businesses.first?.title == "Acme Ltd")
        let counts = try await db.reader.read(SidebarCounts.fetch)
        #expect(counts.chats == 2 && counts.businesses == 1 && counts.unread == 3)
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
        let groups = GroupService(bridge: bridge, ingest: ingest, batchInterval: .zero)
        await groups.fillMissingNames()
        #expect(bridge.calls.withLock { $0.overviews.map(\.count) } == [50, 50, 21])
        #expect(try db.count("SELECT COUNT(*) FROM chat WHERE kind = 'group' AND name IS NULL") == 0)

        try await groups.loadMetadata(jid: F.group)
        #expect(try db.count("SELECT COUNT(*) FROM group_participant WHERE groupJid = ?", [F.group]) == 2)
    }

    @Test func groupCountsFillForGroupsMissingThemAndGoStaleOnMembershipChanges() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let bridge = FakeBridge()
        try await ingest.apply([F.history(chats: [F.chat(F.group, name: "Named")])])
        let groups = GroupService(bridge: bridge, ingest: ingest, batchInterval: .zero)
        await groups.fillMissing()
        // Named but without a count: still fetched.
        #expect(bridge.calls.withLock { $0.overviews } == [[F.group]])
        #expect(try db.chat(F.group)?.participantCount == 3)
        // A subject change does not clobber the count; a membership change marks it stale.
        try await ingest.apply([.group(group: BridgeGroup(jid: F.group, subject: "Renamed", participantCount: 0, participants: []))])
        #expect(try db.chat(F.group)?.participantCount == 3)
        await groups.fillMissing()
        #expect(bridge.calls.withLock { $0.overviews.count } == 1)
        // A count-less overview (truncated answer) is not a membership change: the count stays.
        try await ingest.apply([.group(group: BridgeGroup(jid: F.group, subject: nil, participantCount: 0, participants: []))])
        #expect(try db.chat(F.group)?.participantCount == 3)
        try await ingest.apply([.group(group: BridgeGroup(jid: F.group, subject: nil, participantCount: 0, participants: [],
                                                          membershipChanged: true))])
        #expect(try db.chat(F.group)?.participantCount == nil)
        #expect(try db.chat(F.group)?.name == "Renamed")
        await groups.fillMissing(stale: [F.group])
        #expect(bridge.calls.withLock { $0.overviews.count } == 2)
        #expect(try db.chat(F.group)?.participantCount == 3)
    }

    @Test func joinedGroupIsListedBeforeItsFirstMessage() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let bridge = FakeBridge()
        let jid = "120363000000000077@g.us"
        try await ingest.apply([.group(group: BridgeGroup(jid: jid, subject: nil, participantCount: 0, participants: [],
                                                          membershipChanged: true, joinedAt: 1_700_000_500))])
        #expect(try db.chat(jid)?.lastActivityAt == 1_700_000_500)
        await GroupService(bridge: bridge, ingest: ingest, batchInterval: .zero).fillMissing(stale: [jid])
        #expect(try db.chat(jid)?.name == "Group 1203")
        // Someone else's add changes nothing about when we joined.
        try await ingest.apply([.group(group: BridgeGroup(jid: jid, subject: nil, participantCount: 0, participants: [],
                                                          membershipChanged: true))])
        #expect(try db.chat(jid)?.lastActivityAt == 1_700_000_500)
    }

    @Test func joinedGroupsWithoutAChatAreAddedOnce() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let bridge = FakeBridge()
        let missing = "120363000000000078@g.us"
        try await ingest.apply([F.history(chats: [F.chat(F.group, name: "Named", lastActivity: 1_700_000_000)])])
        bridge.participating = [F.group, missing]
        bridge.metadataJoinedAt = 1_700_000_900
        let groups = GroupService(bridge: bridge, ingest: ingest, batchInterval: .zero)
        await groups.addMissingJoinedGroups()
        #expect(try db.chat(missing)?.name == "Meta \(missing)")
        #expect(try db.chat(missing)?.lastActivityAt == 1_700_000_900)
        // Known groups are left as they are.
        #expect(try db.chat(F.group)?.lastActivityAt == 1_700_000_000)

        bridge.participating.append("120363000000000079@g.us")
        await groups.addMissingJoinedGroups()
        #expect(try db.chat("120363000000000079@g.us") == nil)
    }

    @Test func joinedGroupsCheckListsHiddenRowsButNotCommunities() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let bridge = FakeBridge()
        let hidden = "120363000000000080@g.us", community = "120363000000000081@g.us"
        // Someone else's add created the row without activity.
        try await ingest.apply([.group(group: BridgeGroup(jid: hidden, subject: nil, participantCount: 0, participants: [],
                                                          membershipChanged: true))])
        #expect(try db.chat(hidden)?.lastActivityAt == nil)
        bridge.participating = [hidden, community]
        bridge.communities = [community]
        bridge.metadataJoinedAt = 1_700_000_900
        await GroupService(bridge: bridge, ingest: ingest, batchInterval: .zero).addMissingJoinedGroups()
        #expect(try db.chat(hidden)?.lastActivityAt == 1_700_000_900)
        #expect(try db.chat(community)?.lastActivityAt == nil)
    }

    @Test func ownGroupSendsCarryOurParticipantAndOldRowsAreBackfilled() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let ownLid = "1234@lid"
        try await ingest.apply([.ownJid(pn: F.me, lid: ownLid)])
        // Send result from the bridge: participant filled in (LID-addressed group).
        let pending = try await ingest.insertOutgoing(chatJid: F.group, text: "hi", ownJid: F.me)
        var sent = F.message("S1", chat: F.group, fromMe: true)
        sent.participant = ownLid
        try await ingest.completeSend(localId: pending.id, chatJid: F.group,
                                      result: BridgeSendResult(messageId: "S1", timestamp: 1_700_000_000, message: sent))
        #expect(try db.message(F.group, "S1")?.participant == ownLid)

        // Own rows without one (history copies): filled from the group's addressing on ingest (others
        // are LIDs here), and by the v6 backfill for rows stored earlier.
        let lidGroup = "120363000000000002@g.us", pnGroup = "120363000000000003@g.us"
        var other = F.message("o1", chat: lidGroup, sender: "5555@lid")
        other.participant = "5555@lid"
        var mine = F.message("m1", chat: lidGroup, fromMe: true)
        mine.participant = nil
        var minePn = F.message("m2", chat: pnGroup, fromMe: true)
        minePn.participant = nil
        try await ingest.apply([F.live(other, mine, minePn, F.message("o2", chat: pnGroup, sender: F.bob))])
        #expect(try db.message(lidGroup, "m1")?.participant == ownLid)
        try await db.pool.write { db in
            try db.execute(sql: "UPDATE message SET participant = NULL WHERE fromMe = 1")
            try AppDatabase.backfillOwnGroupParticipants(db)
        }
        #expect(try db.message(F.group, "S1")?.participant == F.me)  // no LID senders in that group
        #expect(try db.message(lidGroup, "m1")?.participant == ownLid)
        #expect(try db.message(pnGroup, "m2")?.participant == F.me)
    }

    @Test func failedOverviewFetchIsRetriedOnTheNextPass() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let bridge = FakeBridge()
        try await ingest.apply([F.history(chats: [F.chat(F.group, name: "Named")])])
        let groups = GroupService(bridge: bridge, ingest: ingest, batchInterval: .zero)
        bridge.overviewsFail = true
        await groups.fillMissing()
        bridge.overviewsFail = false
        await groups.fillMissing()
        #expect(bridge.calls.withLock { $0.overviews.count } == 2)
        #expect(try db.chat(F.group)?.participantCount == 3)
    }

    @Test func aGuessedOwnParticipantNeverOutvotesTheServer() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let ownLid = "1234@lid"
        try await ingest.apply([.ownJid(pn: F.me, lid: ownLid)])
        // History copies of our messages (no participant) in a group with no LID evidence yet:
        // guessed as our phone-number JID.
        var h1 = F.message("h1", chat: F.group, fromMe: true, ts: 100), h2 = F.message("h2", chat: F.group, fromMe: true, ts: 101)
        h1.participant = nil; h2.participant = nil
        try await ingest.apply([F.history(messages: [h1, h2])])
        #expect(try db.message(F.group, "h1")?.participant == F.me)
        // A send whose addressing was unknown (bridge reported none) does not add a vote either.
        let pending = try await ingest.insertOutgoing(chatJid: F.group, text: "x", ownJid: F.me)
        var unknown = F.message("s0", chat: F.group, fromMe: true, ts: 150)
        unknown.participant = nil
        try await ingest.completeSend(localId: pending.id, chatJid: F.group,
                                      result: BridgeSendResult(messageId: "s0", timestamp: 150, message: unknown))
        // One live echo reports our LID: every guessed row follows it, however many there are.
        var echo = F.message("e1", chat: F.group, fromMe: true, ts: 200)
        echo.participant = ownLid
        try await ingest.apply([F.live(echo)])
        for id in ["h1", "h2", "s0"] { #expect(try db.message(F.group, id)?.participant == ownLid) }
        // A later history copy of our message is filled from the echo, not the old guess.
        var h3 = F.message("h3", chat: F.group, fromMe: true, ts: 300)
        h3.participant = nil
        try await ingest.apply([F.history(messages: [h3])])
        #expect(try db.message(F.group, "h3")?.participant == ownLid)
        // A redelivered echo of a guessed row fixes that row too.
        var redelivered = F.message("h1", chat: F.group, fromMe: true, ts: 100)
        redelivered.participant = ownLid
        try await ingest.apply([F.live(redelivered)])
        #expect(try db.count("SELECT COUNT(*) FROM message WHERE id = 'h1' AND participantInferred = 0") == 1)
    }
}
