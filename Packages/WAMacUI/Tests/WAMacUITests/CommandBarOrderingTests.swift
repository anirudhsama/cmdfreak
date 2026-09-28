import Foundation
import Testing
import WAKit
@testable import WAMacUI

/// ⌘K lists actions above chats: with nothing typed, the open chat's actions; with a query, the
/// strong action matches. Weaker action matches mix in with chats by score.
@MainActor @Suite struct CommandBarOrderingTests {
    static let chat = "15551110000@s.whatsapp.net"
    static let other = "15552220000@s.whatsapp.net"

    func makeModel() async throws -> (CommandBarModel, [ChatListItem]) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wamacui-cmdk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let database = try AppDatabase(url: dir.appending(path: "app.sqlite"))
        try await IngestActor(database: database).apply([.messages(messages: [
            Seed.message("m1", chat: Self.chat, sender: Self.chat, ts: 1_700_000_000, text: "hi", pushName: "Maya", status: nil),
            Seed.message("m2", chat: Self.other, sender: Self.other, ts: 1_700_000_001, text: "hey", pushName: "Priya", status: nil),
        ], updates: [])])
        let items = try await database.reader.read { try ChatListQuery.fetch($0, filter: ChatFilter()) }
        let model = CommandBarModel(database: database, usage: QuickSearchUsageStore(url: dir.appending(path: "usage.json")),
                                    registry: .standard())
        model.present(scope: .all, context: CommandContext(chat: items.first { $0.id == Self.chat }))
        return (model, items)
    }

    func results(of model: CommandBarModel, for query: String) async -> [String] {
        model.query = query
        for _ in 0..<100 where !model.hasLoaded || model.query != query {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
        return model.results.map(\.id)
    }

    @Test func emptyQueryListsTheOpenChatsActionsThenChats() async throws {
        let (model, _) = try await makeModel()
        let ids = await results(of: model, for: "")
        #expect(Array(ids.prefix(5)) == ["chat.attach", "chat.unread", "chat.pin", "chat.mute", "chat.archive"].map { "action:" + $0 })
        #expect(ids.dropFirst(5).allSatisfy { $0.hasPrefix("chat:") })
        #expect(ids.count > 5)
    }

    @Test func strongActionMatchesComeFirst() async throws {
        let (model, _) = try await makeModel()
        #expect(await results(of: model, for: "mute").first == "action:chat.mute")
        #expect(await results(of: model, for: "archived").first == "action:go.archived")
    }

    @Test func typingAChatNameStillPutsTheChatFirst() async throws {
        let (model, items) = try await makeModel()
        let title = try #require(items.first { $0.id == Self.other }?.title)
        let ids = await results(of: model, for: title)
        #expect(ids.first == "chat:" + Self.other)
    }
}
