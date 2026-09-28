import AppKit
import Foundation
import Testing
import WAKit
@testable import WAMacUI

/// `ChatViewController` owns `WAClient` focus: it reports the shown chat and its window's key state,
/// and marks the chat read when shown in, or its window becomes, the key window.
@MainActor @Suite(.serialized) struct ChatFocusTests {
    nonisolated static let chat = "15551110000@s.whatsapp.net"

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

        func unread() throws -> Int {
            Int(try client.database.reader.read { try ChatRecord.fetchOne($0, key: ChatFocusTests.chat) }?.unreadCount ?? 0)
        }
    }

    /// A shown, non-key window whose chat has one unread incoming message.
    func makeFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appending(path: "wamacui-focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let client = try WAClient(database: try AppDatabase(url: dir.appending(path: "app.sqlite"))) { _ in HarnessBridge(remoteDir: dir) }
        try await client.ingest.apply([.messages(messages: [
            Seed.message("m1", chat: Self.chat, sender: Self.chat, ts: 1_700_000_000, text: "hi", status: nil),
        ], updates: [])])

        let vc = ChatViewController(client: client, preloader: ChatOpenPreloader())
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        window.orderFront(nil)
        let fixture = Fixture(client: client, vc: vc, window: window)
        #expect(try fixture.unread() == 1)
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

    @Test func showingInAKeyWindowReads() async throws {
        let f = try await makeFixture()
        f.window.setKey(true)
        #expect(f.focus == (nil, true))
        f.vc.show(chatJid: Self.chat)
        #expect(try await eventually { try f.unread() == 0 })
        #expect(f.focus == (Self.chat, true))
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
