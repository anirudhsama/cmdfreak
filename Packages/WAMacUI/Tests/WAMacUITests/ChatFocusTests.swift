import AppKit
import Foundation
import Testing
import WAKit
@testable import WAMacUI

/// `ChatViewController` owns `WAClient` focus: it reports the shown chat, and marks it read once it
/// is on screen in the key window and has stayed there for `readSettleDelay`.
@MainActor @Suite(.serialized) struct ChatFocusTests {
    nonisolated static let chat = "15551110000@s.whatsapp.net"
    nonisolated static let other = "15552220000@s.whatsapp.net"

    final class TestWindow: NSWindow {
        var key = false
        override var isKeyWindow: Bool { key }

        func setKey(_ key: Bool) {
            self.key = key
            NotificationCenter.default.post(name: key ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification, object: self)
        }
    }

    struct Fixture {
        let client: WAClient
        let vc: ChatViewController
        let window: TestWindow

        var focus: (chatJid: String?, windowIsKey: Bool) { client.focus.current }

        func unread(_ jid: String = ChatFocusTests.chat) throws -> Int {
            Int(try client.database.reader.read { try ChatRecord.fetchOne($0, key: jid) }?.unreadCount ?? 0)
        }
    }

    /// A shown, non-key window; each chat has one unread incoming message.
    func makeFixture(settle: Duration = .milliseconds(50)) async throws -> Fixture {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appending(path: "wamacui-focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let client = try WAClient(database: try AppDatabase(url: dir.appending(path: "app.sqlite"))) { _ in HarnessBridge(remoteDir: dir) }
        try await client.ingest.apply([.messages(messages: [
            Seed.message("m1", chat: Self.chat, sender: Self.chat, ts: 1_700_000_000, text: "hi", status: nil),
            Seed.message("m2", chat: Self.other, sender: Self.other, ts: 1_700_000_001, text: "hey", status: nil),
        ], updates: [])])

        let vc = ChatViewController(client: client, preloader: ChatOpenPreloader())
        vc.readSettleDelay = settle
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        window.orderFront(nil)
        let fixture = Fixture(client: client, vc: vc, window: window)
        #expect(try fixture.unread() == 1 && fixture.unread(Self.other) == 1)
        return fixture
    }

    func eventually(_ condition: () throws -> Bool) async rethrows -> Bool {
        for _ in 0..<100 {
            if try condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return try condition()
    }

    @Test func showingInABackgroundWindowFocusesWithoutReading() async throws {
        let f = try await makeFixture()
        f.vc.show(chatJid: Self.chat)
        #expect(f.focus == (Self.chat, false))
        try await Task.sleep(for: .milliseconds(200))
        #expect(try f.unread() == 1)
    }

    @Test func showingInAKeyWindowReadsOnceSettled() async throws {
        let f = try await makeFixture(settle: .milliseconds(300))
        f.window.setKey(true)
        f.vc.show(chatJid: Self.chat)
        #expect(f.focus == (Self.chat, false))
        try await Task.sleep(for: .milliseconds(100))
        #expect(try f.unread() == 1)
        #expect(try await eventually { try f.unread() == 0 })
        #expect(f.focus == (Self.chat, true))
    }

    @Test func flickingThroughChatsDoesNotReadThem() async throws {
        let f = try await makeFixture(settle: .milliseconds(300))
        f.window.setKey(true)
        f.vc.show(chatJid: Self.chat)
        try await Task.sleep(for: .milliseconds(100))
        f.vc.show(chatJid: Self.other)
        #expect(try await eventually { try f.unread(Self.other) == 0 })
        #expect(try f.unread() == 1)
    }

    @Test func resigningKeyBeforeSettlingDoesNotRead() async throws {
        let f = try await makeFixture(settle: .milliseconds(300))
        f.vc.show(chatJid: Self.chat)
        f.window.setKey(true)
        try await Task.sleep(for: .milliseconds(100))
        f.window.setKey(false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try f.unread() == 1)
        #expect(f.focus == (Self.chat, false))
    }

    @Test func windowKeyChangesFollowTheShownChat() async throws {
        let f = try await makeFixture()
        f.vc.show(chatJid: Self.chat)
        f.window.setKey(true)
        #expect(try await eventually { try f.unread() == 0 })
        #expect(f.focus == (Self.chat, true))
        f.window.setKey(false)
        #expect(f.focus == (Self.chat, false))
        f.vc.show(chatJid: nil)
        #expect(f.focus == (nil, false))
    }

    @Test func disappearingClearsFocusAndStopsObserving() async throws {
        let f = try await makeFixture()
        f.vc.show(chatJid: Self.chat)
        f.window.orderOut(nil)
        #expect(f.focus == (nil, false))
        f.window.setKey(true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.focus == (nil, false))
        #expect(try f.unread() == 1)
    }
}
