import Darwin
import Foundation
import Testing
@testable import WAKit

/// Ingests a synthetic 50k-message history in bridge-sized chunks and checks the process footprint.
@Suite(.serialized) struct LargeHistoryTests {
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    @Test func ingest50kMessagesUnder300MB() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        let chats = 400, total = 50_000, perChunk = 500
        let chatJids = (0..<chats).map { i in i % 5 == 0 ? "1203630000\(i)@g.us" : "1555\(String(format: "%07d", i))@s.whatsapp.net" }
        let lorem = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore"

        let start = Date()
        var peak = Self.footprintMB()
        for chunk in 0..<(total / perChunk) {
            let messages: [BridgeMessage] = (0..<perChunk).map { j in
                let n = chunk * perChunk + j
                let chat = chatJids[n % chats]
                let isGroup = chat.hasSuffix("@g.us")
                let sender = isGroup ? "1666\(String(format: "%07d", n % 97))@s.whatsapp.net" : chat
                let hasMedia = n % 10 == 0
                return F.message(
                    "H\(n)", chat: chat, sender: sender, fromMe: n % 3 == 0, ts: 1_600_000_000 + Int64(total - n) * 30,
                    kind: hasMedia ? .image : .text, text: "\(lorem) #\(n)",
                    media: hasMedia ? F.media(sha: UInt8(n % 251)) : nil,
                    reactions: n % 25 == 0 ? [BridgeReaction(senderJid: sender, fromMe: false, emoji: "👍", timestamp: 1)] : [],
                    pushName: isGroup ? "Member \(n % 97)" : nil, status: .read
                )
            }
            let chatRecords = chunk == 0 ? chatJids.map { F.chat($0, lastActivity: nil) } : []
            try await ingest.apply([F.history(chats: chatRecords, messages: messages, type: .recent,
                                              progress: UInt32(chunk), last: chunk == total / perChunk - 1)])
            peak = max(peak, Self.footprintMB())
        }
        let elapsed = Date().timeIntervalSince(start)
        print("50k ingest: \(String(format: "%.2f", elapsed))s, peak footprint \(String(format: "%.1f", peak)) MB")

        #expect(try db.count("SELECT COUNT(*) FROM message") == total)
        #expect(try db.count("SELECT COUNT(*) FROM chat WHERE lastMessageId IS NOT NULL") == chats)
        #expect(peak > 0 && peak < 300)

        let listStart = Date()
        let list = try await db.reader.read { try ChatListQuery.fetch($0, filter: .chats) }
        let page = try await ChatWindowLoader(database: db, chatJid: chatJids[1]).initial()
        print("chat list (\(list.count)) + first page: \(String(format: "%.1f", Date().timeIntervalSince(listStart) * 1000)) ms")
        #expect(list.count == chats)
        #expect(page.items.count == 60)
    }
}
