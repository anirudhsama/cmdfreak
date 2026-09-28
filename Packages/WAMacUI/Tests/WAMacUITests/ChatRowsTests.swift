import Foundation
import Testing
import WAKit
@testable import WAMacUI

enum Fx {
    static let chat = "15551110000@s.whatsapp.net"
    static let group = "120363000000000001@g.us"

    static func item(_ id: String, ts: Int64, fromMe: Bool = false, sender: String? = nil, kind: MessageKind = .text,
                     text: String? = "hi", chat: String = Fx.chat, reactions: [ReactionRecord] = [], status: MessageStatus = .delivered) -> MessageItem {
        let rec = MessageRecord(
            localId: nil, chatJid: chat, id: id, senderJid: sender ?? (fromMe ? "me@s.whatsapp.net" : chat), participant: nil,
            fromMe: fromMe, timestamp: ts, sortKey: SortKey.make(timestamp: ts, seq: Int64(id.hashValue & 0xFFFF)), kind: kind, text: text,
            quotedId: nil, quotedSenderJid: nil, quotedKind: nil, quotedSnippet: nil, status: status, editedAt: nil, revoked: false,
            isForwarded: false, typeName: nil, pushName: nil, extra: nil)
        return MessageItem(message: rec, media: nil, reactions: reactions, pollVotes: [], senderName: fromMe ? nil : "Alice")
    }

    static func reaction(sender: String, emoji: String, fromMe: Bool) -> ReactionRecord {
        ReactionRecord(chatJid: chat, messageId: "a", senderJid: sender, emoji: emoji, fromMe: fromMe, timestamp: 1)
    }

    static func page(_ items: [MessageItem], older: Bool = false, newer: Bool = false) -> MessagePage {
        MessagePage(items: items.sorted { $0.sortKey < $1.sortKey }, hasOlder: older, hasNewer: newer)
    }
}

@Suite struct ChatRowsTests {
    let day: Int64 = 1_700_000_000

    @Test func editAllowedOnlyForOwnSentTextInsideWindow() {
        let now = day + 3_600
        let fresh = now - ChatRows.editWindowSeconds
        #expect(ChatRows.canEdit(Fx.item("a", ts: fresh, fromMe: true), now: now))
        #expect(!ChatRows.canEdit(Fx.item("b", ts: fresh - 1, fromMe: true), now: now))
        #expect(!ChatRows.canEdit(Fx.item("c", ts: now, fromMe: false), now: now))
        #expect(!ChatRows.canEdit(Fx.item("d", ts: now, fromMe: true, kind: .image), now: now))
        #expect(!ChatRows.canEdit(Fx.item("e", ts: now, fromMe: true, status: .failed), now: now))
    }

    @Test func buildsDaySeparatorsAndGrouping() {
        var rows = ChatRows(chatJid: Fx.chat, isGroupChat: false)
        rows.replace(with: Fx.page([
            Fx.item("a", ts: day), Fx.item("b", ts: day + 60), Fx.item("c", ts: day + 86_400 * 2),
        ]))
        #expect(rows.rows.count == 5)
        #expect(rows.row(at: 0) == .day(ChatRows.dayStart(day)))
        #expect(rows.row(at: 3) == .day(ChatRows.dayStart(day + 86_400 * 2)))
        let a = rows.context(forMessageAt: 0, width: 600, ownJid: nil, peerName: nil)
        let b = rows.context(forMessageAt: 1, width: 600, ownJid: nil, peerName: nil)
        #expect(a.isFirstInGroup && !a.isLastInGroup)
        #expect(!b.isFirstInGroup && b.isLastInGroup)
    }

    @Test func gapBreaksRun() {
        var rows = ChatRows(chatJid: Fx.chat, isGroupChat: false)
        rows.replace(with: Fx.page([Fx.item("a", ts: day), Fx.item("b", ts: day + 20 * 60)]))
        #expect(rows.context(forMessageAt: 0, width: 600, ownJid: nil, peerName: nil).isLastInGroup)
        #expect(rows.context(forMessageAt: 1, width: 600, ownJid: nil, peerName: nil).isFirstInGroup)
    }

    @Test func appendAtBottomReloadsPreviousTail() {
        var rows = ChatRows(chatJid: Fx.chat, isGroupChat: false)
        rows.replace(with: Fx.page([Fx.item("a", ts: day), Fx.item("b", ts: day + 10)]))
        let u = rows.apply(.add([Fx.item("c", ts: day + 20)]))
        #expect(u.inserted == IndexSet(integer: 3))
        #expect(u.removed.isEmpty)
        #expect(u.reloaded == IndexSet(integer: 2))
        #expect(rows.rowIndex["c"] == 3)
    }

    @Test func prependKeepsIndexesConsistent() {
        var rows = ChatRows(chatJid: Fx.chat, isGroupChat: false)
        rows.replace(with: Fx.page([Fx.item("c", ts: day + 86_400)], older: true))
        let u = rows.prepend(Fx.page([Fx.item("a", ts: day), Fx.item("b", ts: day + 5)]))
        #expect(u.inserted == IndexSet([0, 1, 2]))
        #expect(rows.rows == [.day(ChatRows.dayStart(day)), .message("a"), .message("b"), .day(ChatRows.dayStart(day + 86_400)), .message("c")])
    }

    @Test func deleteRemovesRowAndOrphanDaySeparator() {
        var rows = ChatRows(chatJid: Fx.chat, isGroupChat: false)
        rows.replace(with: Fx.page([Fx.item("a", ts: day), Fx.item("b", ts: day + 86_400)]))
        let u = rows.apply(.delete(ids: ["b"]))
        #expect(u.removed == IndexSet([2, 3]))
        #expect(rows.rows.count == 2)
    }

    @Test func updateReloadsRowOnly() {
        var rows = ChatRows(chatJid: Fx.chat, isGroupChat: false)
        rows.replace(with: Fx.page([Fx.item("a", ts: day), Fx.item("b", ts: day + 1)]))
        var edited = Fx.item("b", ts: day + 1)
        edited.message.text = "edited"
        let u = rows.apply(.update([edited]))
        #expect(u.reloaded == IndexSet(integer: 2))
        #expect(u.inserted.isEmpty && u.removed.isEmpty)
        #expect(rows.item(id: "b")?.message.text == "edited")
    }

    @Test func replaceSwapsOptimisticId() {
        var rows = ChatRows(chatJid: Fx.chat, isGroupChat: false)
        rows.replace(with: Fx.page([Fx.item("local-1", ts: day, fromMe: true, status: .pending)]))
        let u = rows.apply(.replace(oldId: "local-1", item: Fx.item("SRV", ts: day, fromMe: true, status: .sent)))
        #expect(u.removed == IndexSet(integer: 1))
        #expect(u.inserted == IndexSet(integer: 1))
        #expect(rows.item(id: "SRV") != nil && rows.item(id: "local-1") == nil)
    }

    @Test func addOutsideWindowIsIgnoredWhenMorePagesExist() {
        var rows = ChatRows(chatJid: Fx.chat, isGroupChat: false)
        rows.replace(with: Fx.page([Fx.item("b", ts: day + 100)], older: true))
        let u = rows.apply(.add([Fx.item("a", ts: day)]))
        #expect(u.isEmpty)
        #expect(rows.messages.count == 1)
    }

    @Test func unreadSeparatorBeforeFirstUnread() {
        var rows = ChatRows(chatJid: Fx.chat, isGroupChat: false)
        rows.replace(with: Fx.page([Fx.item("a", ts: day), Fx.item("me", ts: day + 1, fromMe: true), Fx.item("b", ts: day + 2), Fx.item("c", ts: day + 3)]))
        rows.setUnread(count: 2)
        #expect(rows.rows == [.day(ChatRows.dayStart(day)), .message("a"), .message("me"), .unread, .message("b"), .message("c")])
    }
}
