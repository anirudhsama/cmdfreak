import Foundation
import Testing
@testable import WAKit

@Suite struct NoticeTests {
    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    private func incoming(_ notices: [NoticeEvent]) -> [IncomingNotice] {
        notices.compactMap { if case .incoming(let n) = $0 { n } else { nil } }
    }

    @Test func liveIncomingNotifiesLatestPerChat() async throws {
        let ingest = try IngestActor(database: F.tempDB())
        try await ingest.apply([F.live(F.message("0", chat: F.bob, ts: now - 600))])
        try await ingest.setAvatar(jid: F.bob, path: "/tmp/bob.jpg", checkedAt: now)
        let result = try await ingest.applyBatch([
            .contacts(contacts: [BridgeContact(jid: F.alicePN, fullName: "Alice", firstName: nil, pushName: nil, phone: nil)]),
            F.live(F.message("1", chat: F.bob, ts: now - 1, text: "first"), F.message("2", chat: F.bob, ts: now, text: "second"),
                   F.message("3", chat: F.group, sender: F.alicePN, ts: now, kind: .image, text: nil),
                   F.message("4", chat: F.bob, fromMe: true, ts: now)),
        ])
        let notices = incoming(result.notices)
        #expect(notices.count == 2)
        let dm = try #require(notices.first { $0.chatJid == F.bob })
        #expect(dm.messageId == "2" && dm.text == "second" && dm.senderName == nil)
        #expect(dm.avatarPath == "/tmp/bob.jpg")
        let group = try #require(notices.first { $0.chatJid == F.group })
        #expect(group.senderName == "Alice" && group.kind == .image)
    }

    @Test func silentWhenFocusedMutedArchivedOldOrHistory() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([.chatAction(action: .mute(chatJid: F.bob, mutedUntil: Int64.max))])
        try await ingest.apply([.chatAction(action: .archive(chatJid: F.alicePN, archived: true))])
        ingest.focus.set(chatJid: F.group, windowIsKey: true)
        var result = try await ingest.applyBatch([F.live(
            F.message("1", chat: F.bob, ts: now), F.message("2", chat: F.alicePN, ts: now),
            F.message("3", chat: F.group, sender: F.bob, ts: now))])
        #expect(incoming(result.notices).isEmpty)

        ingest.focus.set(chatJid: nil, windowIsKey: false)
        result = try await ingest.applyBatch([F.live(F.message("4", chat: F.group, sender: F.bob, ts: now - 600))])
        #expect(incoming(result.notices).isEmpty)
        result = try await ingest.applyBatch([F.history(chats: [], messages: [F.message("5", chat: F.group, sender: F.bob, ts: now)])])
        #expect(incoming(result.notices).isEmpty)
    }

    @Test func readOrRevokeWithdraws() async throws {
        let ingest = try IngestActor(database: F.tempDB())
        var result = try await ingest.applyBatch([
            F.live(F.message("1", chat: F.bob, ts: now)),
            F.receipt(["1"], chat: F.bob, kind: .readSelf, from: F.me),
        ])
        #expect(result.notices == [.chatRead(F.bob)])

        result = try await ingest.applyBatch([F.live(F.message("2", chat: F.bob, ts: now),
                                                     updates: [.revoke(target: F.key("2", chat: F.bob), revokedBy: F.bob, timestamp: now)])])
        #expect(result.notices == [.messageRemoved(chatJid: F.bob, messageId: "2")])
    }

    @Test func streamCarriesNoticesAndOpenedChat() async throws {
        let ingest = try IngestActor(database: F.tempDB())
        try await ingest.apply([F.live(F.message("1", chat: F.bob, ts: now))])
        _ = try await ingest.chatOpened(F.bob)
        var it = ingest.notices.makeAsyncIterator()
        guard case .incoming(let n) = await it.next() else { Issue.record("expected incoming"); return }
        #expect(n.messageId == "1")
        #expect(await it.next() == .chatRead(F.bob))
    }

    @Test func newestCandidateWinsRegardlessOfArrivalOrder() async throws {
        let ingest = try IngestActor(database: F.tempDB())
        let result = try await ingest.applyBatch([F.live(F.message("new", chat: F.bob, ts: now), F.message("old", chat: F.bob, ts: now - 600))])
        #expect(incoming(result.notices).map(\.messageId) == ["new"])
    }

    @Test func aliasMergeMidBatchNotifiesOnceUnderPhoneNumber() async throws {
        let ingest = try IngestActor(database: F.tempDB())
        let result = try await ingest.applyBatch([
            F.live(F.message("1", chat: F.aliceLID, ts: now)),
            .jidAliases(aliases: [BridgeJidAlias(lid: F.aliceLID, pn: F.alicePN)]),
            F.live(F.message("2", chat: F.alicePN, ts: now - 1)),
        ])
        let notices = incoming(result.notices)
        #expect(notices.count == 1 && notices.first?.chatJid == F.alicePN && notices.first?.messageId == "1")
    }

    @Test func partialClearWithdrawsOnlyClearedMessages() async throws {
        let ingest = try IngestActor(database: F.tempDB())
        try await ingest.apply([F.live(F.message("1", chat: F.bob, ts: now - 10), F.message("2", chat: F.bob, ts: now))])
        let result = try await ingest.applyBatch([.chatAction(action: .clear(chatJid: F.bob, cutoff: now - 5))])
        #expect(result.notices == [.messageRemoved(chatJid: F.bob, messageId: "1")])
    }

    @Test func revokedRedeliveryWithdraws() async throws {
        let ingest = try IngestActor(database: F.tempDB())
        try await ingest.apply([F.live(F.message("1", chat: F.bob, ts: now))])
        let result = try await ingest.applyBatch([F.live(F.message("1", chat: F.bob, ts: now, text: nil, revoked: true))])
        #expect(result.notices == [.messageRemoved(chatJid: F.bob, messageId: "1")])
    }

    @Test func placeholderAlertsOnUpgradeOnlyWhileUnread() async throws {
        let ingest = try IngestActor(database: F.tempDB())
        var result = try await ingest.applyBatch([F.live(F.message("1", chat: F.bob, ts: now, kind: .undecryptable, text: nil))])
        #expect(incoming(result.notices).isEmpty)
        result = try await ingest.applyBatch([F.live(F.message("1", chat: F.bob, ts: now))])
        #expect(incoming(result.notices).map(\.messageId) == ["1"])

        try await ingest.apply([F.live(F.message("2", chat: F.bob, ts: now, kind: .undecryptable, text: nil))])
        try await ingest.apply([F.receipt(["2"], chat: F.bob, kind: .readSelf, from: F.me)])
        result = try await ingest.applyBatch([F.live(F.message("2", chat: F.bob, ts: now))])
        #expect(incoming(result.notices).isEmpty)
    }

    @Test func statusAndNewslettersStaySilent() async throws {
        let ingest = try IngestActor(database: F.tempDB())
        let result = try await ingest.applyBatch([F.live(
            F.message("1", chat: "status@broadcast", sender: F.bob, ts: now),
            F.message("2", chat: "120363000000000009@newsletter", ts: now))])
        #expect(incoming(result.notices).isEmpty)
    }

    @Test func lateDecryptRetryStillAlerts() async throws {
        let ingest = try IngestActor(database: F.tempDB())
        try await ingest.apply([F.live(F.message("1", chat: F.bob, ts: now - 600, kind: .undecryptable, text: nil))])
        let result = try await ingest.applyBatch([F.live(F.message("1", chat: F.bob, ts: now - 600))])
        #expect(incoming(result.notices).map(\.messageId) == ["1"])
    }

    @Test func badgeCountsUnmutedUnarchivedAndFindsNextMuteExpiry() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let group2 = "120363000000000002@g.us"
        try await ingest.apply([F.live(
            F.message("1", chat: F.bob), F.message("2", chat: F.alicePN), F.message("3", chat: F.group, sender: F.bob),
            F.message("4", chat: group2, sender: F.bob))])
        try await ingest.apply([
            .chatAction(action: .mute(chatJid: F.alicePN, mutedUntil: now + 3600)),
            .chatAction(action: .mute(chatJid: group2, mutedUntil: Int64.max)),
            .chatAction(action: .archive(chatJid: F.group, archived: true)),
        ])
        let state = try db.badgeState()
        #expect(state.count == 1)
        #expect(state.nextMuteExpiry == now + 3600)
    }
}
