import Foundation
import GRDB
import Testing
@testable import WAKit

/// Outbound changes stay in `outbox` until the bridge reports the server confirmed them.
@Suite struct OutboxTests {
    enum Change: CaseIterable, Sendable {
        case reaction, edit, revoke, pin, mute, archive, markUnread

        var kind: String {
            switch self {
            case .reaction: "reaction"
            case .edit: "edit"
            case .revoke: "revoke"
            case .pin: "pin"
            case .mute: "mute"
            case .archive: "archive"
            case .markUnread: "markRead"
            }
        }

        func perform(_ client: WAClient) async throws {
            let key = F.key("m", chat: F.bob, fromMe: true)
            switch self {
            case .reaction: try await client.react(to: key, emoji: "👍")
            case .edit: try await client.edit(key, text: "edited")
            case .revoke: try await client.revoke(key)
            case .pin: try await client.setPinned(F.bob, true)
            case .mute: try await client.setMuted(F.bob, until: .max)
            case .archive: try await client.setArchived(F.bob, true)
            case .markUnread: try await client.setRead(F.bob, false)
            }
        }

        /// Bridge calls made for it.
        func sent(_ bridge: FakeBridge) -> Int {
            bridge.calls.withLock { c in
                switch self {
                case .reaction: c.reactions.filter { $0.id == "m" && $0.emoji == "👍" }.count
                case .edit: c.edits.filter { $0.id == "m" && $0.text == "edited" }.count
                case .revoke: c.revokes.filter { $0 == "m" }.count
                case .pin: c.pins.filter { $0 == (F.bob, true) }.count
                case .mute: c.mutes.filter { $0.0 == F.bob && $0.1 == .max }.count
                case .archive: c.archives.filter { $0 == (F.bob, true) }.count
                case .markUnread: c.markChatRead.filter { $0 == (F.bob, false) }.count
                }
            }
        }

        /// The same kind of change made on another device, undoing this one.
        var remote: BridgeChatAction? {
            switch self {
            case .pin: .pin(chatJid: F.bob, pinnedAt: nil)
            case .mute: .mute(chatJid: F.bob, mutedUntil: nil)
            case .archive: .archive(chatJid: F.bob, archived: false)
            case .markUnread: .markRead(chatJid: F.bob, read: true)
            case .reaction, .edit, .revoke: nil
            }
        }
    }

    private func setUp() async throws -> (AppDatabase, FakeBridge, WAClient, any EventSink) {
        let db = try F.tempDB()
        let bridge = FakeBridge()
        let (client, sink) = try await makeClient(db, bridge)
        await deliver(sink, [F.live(F.message("m", chat: F.bob, fromMe: true, text: "hi"))])
        return (db, bridge, client, sink)
    }

    private func queued(_ db: AppDatabase, _ kind: String? = nil) throws -> Int {
        try kind.map { try db.count("SELECT COUNT(*) FROM outbox WHERE kind = ?", [$0]) } ?? db.count("SELECT COUNT(*) FROM outbox")
    }

    /// Waits for the pass that tried rows of `kind` and failed.
    private func waitForFailure(_ db: AppDatabase, _ kind: String) async throws {
        try await waitFor { try db.count("SELECT COUNT(*) FROM outbox WHERE kind = ? AND lastError IS NOT NULL", [kind]) > 0 }
    }

    @Test(arguments: Change.allCases)
    func aFailedSendStaysQueuedAndGoesAfterReconnect(_ change: Change) async throws {
        let (db, bridge, client, sink) = try await setUp()
        bridge.actionsFail = true
        try await change.perform(client)
        try await waitForFailure(db, change.kind)
        #expect(change.sent(bridge) == 1)
        #expect(try queued(db, change.kind) == 1)

        bridge.actionsFail = false
        await deliver(sink, [.connection(state: .connected)])
        try await waitFor { try queued(db) == 0 }
        #expect(try queued(db) == 0)
        #expect(change.sent(bridge) == 2)
    }

    @Test(arguments: Change.allCases)
    func confirmationRemovesTheRow(_ change: Change) async throws {
        let (db, bridge, client, _) = try await setUp()
        try await change.perform(client)
        #expect(try queued(db, change.kind) == 1)
        await client.outbox.flush()
        #expect(change.sent(bridge) == 1)
        #expect(try queued(db) == 0)
    }

    @Test(arguments: Change.allCases.filter { $0.remote != nil })
    func aChatActionFromAnotherDeviceDropsOurs(_ change: Change) async throws {
        let (db, bridge, client, sink) = try await setUp()
        bridge.actionsFail = true
        try await change.perform(client)
        try await waitForFailure(db, change.kind)
        await deliver(sink, [.chatAction(action: try #require(change.remote))])
        #expect(try queued(db) == 0)

        bridge.actionsFail = false
        await deliver(sink, [.connection(state: .connected)])
        await client.outbox.flush()
        try await Task.sleep(for: .milliseconds(100))
        #expect(change.sent(bridge) == 1)
    }

    @Test func aChatActionOvertakenLocallyIsNotSent() async throws {
        let (db, bridge, client, sink) = try await setUp()
        bridge.actionsFail = true
        try await client.setArchived(F.bob, true)
        try await waitForFailure(db, "archive")
        // The local state moved on without a queued change of ours (a history snapshot).
        try await db.pool.write { try $0.execute(sql: "UPDATE chat SET archived = 0 WHERE jid = ?", arguments: [F.bob]) }
        bridge.actionsFail = false
        await deliver(sink, [.connection(state: .connected)])
        try await waitFor { try queued(db) == 0 }
        #expect(try queued(db) == 0)
        #expect(Change.archive.sent(bridge) == 1)
    }

    @Test func aNewerReactionOrEditReplacesTheQueuedOne() async throws {
        let (db, bridge, client, sink) = try await setUp()
        let key = F.key("m", chat: F.bob, fromMe: true)
        bridge.actionsFail = true
        try await client.react(to: key, emoji: "😮")
        try await client.edit(key, text: "first")
        try await client.react(to: key, emoji: "👍")
        try await client.edit(key, text: "edited")
        #expect(try queued(db) == 2)

        bridge.actionsFail = false
        await deliver(sink, [.connection(state: .connected)])
        try await waitFor { try queued(db) == 0 }
        let calls = bridge.calls.withLock { $0 }
        #expect(!calls.reactions.contains { $0.emoji == "😮" })
        #expect(!calls.edits.contains { $0.text == "first" })
        #expect(Change.reaction.sent(bridge) >= 1)
        #expect(Change.edit.sent(bridge) >= 1)
    }

    @Test func aReactionOvertakenByAnotherDeviceIsNotSent() async throws {
        let (db, bridge, client, sink) = try await setUp()
        bridge.actionsFail = true
        try await client.react(to: F.key("m", chat: F.bob, fromMe: true), emoji: "👍")
        try await waitForFailure(db, "reaction")
        // Our phone reacted after it.
        let later = BridgeReaction(senderJid: F.me, fromMe: true, emoji: "❤️", timestamp: Int64(Date().timeIntervalSince1970) + 5)
        await deliver(sink, [F.live(updates: [.reaction(target: F.key("m", chat: F.bob, fromMe: true), reaction: later)])])
        bridge.actionsFail = false
        await deliver(sink, [.connection(state: .connected)])
        try await waitFor { try queued(db) == 0 }
        #expect(try queued(db) == 0)
        #expect(Change.reaction.sent(bridge) == 1)
    }

    @Test func aRevokeDropsQueuedEditsAndReactions() async throws {
        let (db, bridge, client, sink) = try await setUp()
        let key = F.key("m", chat: F.bob, fromMe: true)
        bridge.actionsFail = true
        try await client.edit(key, text: "edited")
        try await client.react(to: key, emoji: "👍")
        try await client.revoke(key)
        #expect(try queued(db) == 1)
        #expect(try queued(db, "revoke") == 1)

        bridge.actionsFail = false
        await deliver(sink, [.connection(state: .connected)])
        try await waitFor { try queued(db) == 0 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(Change.revoke.sent(bridge) >= 1)
        #expect(bridge.calls.withLock { $0.edits.isEmpty && $0.reactions.isEmpty })
    }

    @Test func givingUpUndoesTheLocalChange() async throws {
        let db = try F.tempDB()
        let bridge = FakeBridge()
        let (client, sink) = try await makeClient(db, bridge)
        let key = F.key("m", chat: F.bob, fromMe: true)
        await deliver(sink, [F.live(F.message("m", chat: F.bob, fromMe: true, kind: .image, text: "caption", media: F.media()))])
        try await client.react(to: key, emoji: "😮")
        await client.outbox.flush()
        #expect(try queued(db) == 0)

        await deliver(sink, [.connection(state: .connected)])
        bridge.actionsFail = true
        try await client.react(to: key, emoji: "👍")
        try await client.edit(key, text: "edited")
        try await client.setPinned(F.bob, true)
        for _ in 0..<100 where try queued(db) > 0 {
            await client.outbox.flush()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try queued(db) == 0)
        #expect(Change.pin.sent(bridge) == Outbox.maxAttempts)
        #expect(try db.chat(F.bob)?.pinnedAt == nil)
        #expect(try db.message(F.bob, "m")?.text == "caption")
        #expect(try db.count("SELECT COUNT(*) FROM reaction WHERE messageId = 'm' AND fromMe AND emoji = '😮'") == 1)

        // A revoke given up on brings the message back as the server has it: media included, and
        // without the edit it dropped from the queue.
        try await client.edit(key, text: "edited again")
        try await client.revoke(key)
        #expect(try db.message(F.bob, "m")?.revoked == true)
        for _ in 0..<100 where try queued(db) > 0 {
            await client.outbox.flush()
            try await Task.sleep(for: .milliseconds(10))
        }
        let m = try #require(try db.message(F.bob, "m"))
        #expect(!m.revoked && m.text == "caption")
        #expect(try db.count("SELECT COUNT(*) FROM media WHERE messageId = 'm'") == 1)
    }

    @Test func theEchoOfOurOwnChatActionDoesNotUndoANewerOne() async throws {
        let (db, bridge, client, sink) = try await setUp()
        try await client.setPinned(F.bob, true)
        await client.outbox.flush()
        #expect(try queued(db) == 0)
        bridge.actionsFail = true
        try await client.setPinned(F.bob, false)
        // The library's re-sync after the pin replays it to us.
        await deliver(sink, [.chatAction(action: .pin(chatJid: F.bob, pinnedAt: 1_700_000_000))])
        #expect(try db.chat(F.bob)?.pinnedAt == nil)
        #expect(try queued(db, "pin") == 1)

        bridge.actionsFail = false
        await deliver(sink, [.connection(state: .connected)])
        try await waitFor { try queued(db) == 0 }
        #expect(bridge.calls.withLock { $0.pins.last.map { $0 == (F.bob, false) } } == true)
    }

    @Test func failuresWhileDisconnectedDoNotCount() async throws {
        let (db, bridge, client, sink) = try await setUp()
        await deliver(sink, [.connection(state: .disconnected(reason: "test"))])
        bridge.actionsFail = true
        try await client.setPinned(F.bob, true)
        for _ in 0..<(Outbox.maxAttempts + 2) { await client.outbox.flush() }
        #expect(try queued(db, "pin") == 1)
        #expect(try db.count("SELECT attempts FROM outbox") == 0)
        #expect(try db.chat(F.bob)?.pinnedAt != nil)
    }

    @Test func queuedReadReceiptsSurviveTheMigration() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v14")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO chat (jid, kind) VALUES (?, 'dm')", arguments: [F.bob])
            for id in ["1", "2"] {
                try db.execute(sql: """
                    INSERT INTO message (chatJid, id, senderJid, fromMe, timestamp, sortKey, kind, status)
                    VALUES (?, ?, ?, 0, 1, 1, 'text', 0)
                    """, arguments: [F.bob, id, F.bob])
            }
            try db.execute(sql: "INSERT INTO read_outbox (chatJid, messageId, queuedAt) VALUES (?, '1', 100)", arguments: [F.bob])
            // Sent on a connection that died before the ack: owed all the same.
            try db.execute(sql: "INSERT INTO read_outbox (chatJid, messageId, queuedAt, ackId) VALUES (?, '2', 101, '2')", arguments: [F.bob])
        }
        try AppDatabase.migrator.migrate(queue)
        let rows = try queue.read { try Row.fetchAll($0, sql: "SELECT kind, chatJid, messageId, queuedAt, payload FROM outbox ORDER BY messageId") }
        #expect(rows.map { $0["kind"] as String } == ["receipt", "receipt"])
        #expect(rows.map { $0["chatJid"] as String } == [F.bob, F.bob])
        #expect(rows.map { $0["messageId"] as String } == ["1", "2"])
        #expect(rows.map { $0["queuedAt"] as Int64 } == [100, 101])
        #expect(try JSONDecoder().decode(OutboxChange.self, from: Data((rows[0]["payload"] as String).utf8)) == .receipt)
        #expect(try queue.read { try $0.tableExists("read_outbox") } == false)
    }
}
