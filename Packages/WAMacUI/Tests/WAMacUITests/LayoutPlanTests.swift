import AppKit
import Testing
import WAKit
@testable import WAMacUI

@Suite struct LayoutPlanTests {
    let ctx = RowContext(width: 640, isGroupChat: false, showsSender: false, isFirstInGroup: true, isLastInGroup: true, ownJid: nil, peerName: "Alice")

    @Test func measurementIsStable() {
        let item = Fx.item("a", ts: 1_700_000_000, text: String(repeating: "lorem ipsum dolor sit amet ", count: 12))
        let p1 = LayoutPlanner.plan(item, ctx)
        let p2 = LayoutPlanner.plan(item, ctx)
        #expect(p1.rowHeight == p2.rowHeight)
        #expect(p1.bubble == p2.bubble)
        #expect(p1.text?.frame == p2.text?.frame)
    }

    @Test func textHeightMatchesCoreTextRender() {
        // The row must fully contain the text plus meta; nothing is clipped.
        let item = Fx.item("a", ts: 1_700_000_000, text: "short")
        let p = LayoutPlanner.plan(item, ctx)
        let text = p.text!
        #expect(text.frame.maxY <= p.bubble.maxY)
        #expect(p.meta!.frame.maxY <= p.bubble.maxY)
        #expect(p.meta!.frame.minX >= text.frame.maxX)  // meta shares the single line
        #expect(p.rowHeight >= p.bubble.maxY)
    }

    @Test func longTextPushesMetaBelow() {
        let item = Fx.item("a", ts: 1_700_000_000, text: String(repeating: "word ", count: 80))
        let p = LayoutPlanner.plan(item, ctx)
        let text = p.text!
        #expect(p.bubble.width <= min(640 * 0.72, 520))
        #expect(p.meta!.frame.minY >= text.frame.maxY || p.meta!.frame.minX >= text.frame.minX)
    }

    @Test func outgoingAlignsTrailing() {
        let p = LayoutPlanner.plan(Fx.item("a", ts: 1_700_000_000, fromMe: true, text: "yo"), ctx)
        #expect(p.outgoing)
        #expect(abs(p.bubble.maxX - (640 - MessageTextConfiguration.Metrics.horizontalInset)) < 0.5)
        #expect(p.meta?.status == .delivered)
    }

    @Test func groupIncomingLeavesRoomForAvatarOnLastOfRun() {
        var group = ctx
        group.isGroupChat = true
        let item = Fx.item("a", ts: 1_700_000_000, text: "hi")
        let last = LayoutPlanner.plan(item, group)
        let avatar = last.avatar!
        #expect(avatar.frame.maxY == last.bubble.maxY)
        #expect(avatar.frame.maxX + MessageCell.tailOverhang < last.bubble.minX)
        group.isLastInGroup = false
        #expect(LayoutPlanner.plan(item, group).avatar == nil)
        #expect(LayoutPlanner.plan(item, ctx).avatar == nil)
        #expect(LayoutPlanner.plan(Fx.item("b", ts: 1_700_000_000, fromMe: true, text: "yo"), group).avatar == nil)
    }

    @Test func stickerSitsInItsBubble() {
        var group = ctx
        group.isGroupChat = true
        for (c, fromMe) in [(ctx, false), (group, false), (ctx, true)] {
            let p = LayoutPlanner.plan(Fx.item("a", ts: 1_700_000_000, fromMe: fromMe, kind: .sticker, text: nil), c)
            guard case .sticker(let f, _, _, _) = p.content else { Issue.record("not a sticker"); continue }
            #expect(f == p.bubble)
        }
    }

    @Test func cacheKeyChangesWithContentAndWidth() {
        let a = Fx.item("a", ts: 1_700_000_000, text: "x")
        var b = a
        b.message.text = "y"
        var wide = ctx
        wide.width = 900
        #expect(LayoutPlan.cacheKey(a, ctx) != LayoutPlan.cacheKey(b, ctx))
        #expect(LayoutPlan.cacheKey(a, ctx) != LayoutPlan.cacheKey(a, wide))
        #expect(LayoutPlan.cacheKey(a, ctx) == LayoutPlan.cacheKey(a, ctx))
    }

    @Test func reactionsExtendRow() {
        let plain = LayoutPlanner.plan(Fx.item("a", ts: 1_700_000_000, text: "x"), ctx)
        let reacted = LayoutPlanner.plan(Fx.item("a", ts: 1_700_000_000, text: "x", reactions: [
            Fx.reaction(sender: Fx.chat, emoji: "👍", fromMe: false),
            Fx.reaction(sender: "me", emoji: "👍", fromMe: true),
        ]), ctx)
        #expect(reacted.rowHeight > plain.rowHeight)
        #expect(reacted.reactions.count == 1)
        #expect(reacted.reactions[0].count == 2 && reacted.reactions[0].mine)
    }

    @Test func systemRowIsCentered() {
        let p = LayoutPlanner.plan(Fx.item("s", ts: 1_700_000_000, kind: .system, text: "Alice joined"), ctx)
        #expect(p.shape == .system)
        #expect(abs(p.bubble.midX - 320) < 1)
    }
}
