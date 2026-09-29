import Foundation
import WAKit

// demo-gen — writes CmdFreak/Demo/Resources/Demo/demo.sqlite from Content.swift.
//
// The chats go through WAKit's IngestActor as one history-sync chunk, exactly as a freshly linked
// account's would, so the file has the current schema and every derived column. Media and avatars
// are read from the same folder and bundled with the demo app as they are.

let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardizedFileURL
let out = repo.appending(path: "CmdFreak/Demo/Resources/Demo", directoryHint: .isDirectory)
let media = MediaLibrary(dir: out.appending(path: "media", directoryHint: .isDirectory))

let chats = try buildChats(media)
let people = Set(chats.flatMap(\.members).map(\.jid))
let contacts = ([Cast.me] + chats.flatMap(\.members) + Cast.idle)
    .reduce(into: [String: BridgeContact]()) { $0[$1.jid] = $1.contact }
    .values.sorted { $0.jid < $1.jid }

let scratch = FileManager.default.temporaryDirectory.appending(path: "demo-gen-\(UUID().uuidString)", directoryHint: .isDirectory)
defer { try? FileManager.default.removeItem(at: scratch) }
let database = try AppDatabase(url: scratch.appending(path: "app.sqlite"))
let ingest = try IngestActor(database: database)

let events: [BridgeEvent] = [.ownJid(pn: Cast.me.jid, lid: nil),
                             .historyChunk(chunk: BridgeHistoryChunk(
                                 syncType: .recent, chunkOrder: 0, progress: 100, chats: chats.map(\.bridgeChat),
                                 messages: chats.flatMap(\.messages), updates: chats.flatMap(\.updates), contacts: contacts,
                                 aliases: [], isLastInPayload: true))]
    + chats.compactMap(\.group).map { .group(group: $0) }
try await ingest.apply(events)
// Answered up front so the app never asks; the demo shifts `checkedAt` along with everything else.
let businesses = Set(Cast.businesses.map(\.jid))
try await ingest.setBusiness(people.sorted().map {
    BridgeBusinessCheck(jid: $0, isBusiness: businesses.contains($0), verifiedName: nil)
}, checkedAt: Clock.now)

let target = out.appending(path: "demo.sqlite")
try? FileManager.default.removeItem(at: target)
try await database.pool.writeWithoutTransaction { db in
    try db.execute(sql: "VACUUM INTO ?", arguments: [target.path])
}

let counts = try await database.pool.read { db in
    (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat") ?? 0, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0)
}
print("wrote \(target.path): \(counts.0) chats, \(counts.1) messages")
