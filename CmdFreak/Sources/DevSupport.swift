#if DEBUG
import AppKit
import Foundation
import WAKit
import WAMacUI

/// Debug-only launch controls, all via environment variables:
/// - `CMDFREAK_SEED=N`: use a throwaway database under Caches and fill it with N synthetic chats.
/// - `CMDFREAK_SEED_LIVE=1`: with a seed, keep ingesting new messages and typing events.
/// - `CMDFREAK_SELFTEST=1`: with a seed, drive every menu shortcut and the command bar with
///   synthetic key events and print PASS/FAIL lines (`ShortcutSelfTest`).
/// - `CMDFREAK_ONBOARDING=qr|phone|code|syncing|loggedout`: force an onboarding state with no bridge calls.
enum DevSupport {
    static let env = ProcessInfo.processInfo.environment

    static var seedCount: Int? { env["CMDFREAK_SEED"].flatMap(Int.init).map { max($0, 1) } }
    static var seedLive: Bool { env["CMDFREAK_SEED_LIVE"] == "1" }
    static var forcedOnboarding: String? { env["CMDFREAK_ONBOARDING"] }
    /// `CMDFREAK_SNAPSHOT=<dir>`: render every window to PNG a few seconds after launch (no Screen
    /// Recording permission needed; glass materials do not composite in this path).
    static var snapshotDirectory: String? { env["CMDFREAK_SNAPSHOT"] }

    @MainActor
    static func runSnapshots(main: MainWindowController?) async {
        guard let dir = snapshotDirectory else { return }
        try? await Task.sleep(for: .seconds(2))
        if let main {
            main.selectChat(at: 1)
            try? await Task.sleep(for: .milliseconds(400))
            snapshot(in: dir, suffix: "chats")
            main.selectRailItem(NSMenuItem(title: "", action: nil, keyEquivalent: "").with(tag: 4))
            try? await Task.sleep(for: .milliseconds(400))
            snapshot(in: dir, suffix: "archived")
            main.selectRailItem(NSMenuItem(title: "", action: nil, keyEquivalent: "").with(tag: 1))
        } else {
            snapshot(in: dir, suffix: "onboarding")
        }
    }

    @MainActor
    private static func snapshot(in dir: String, suffix: String) {
        if let main = NSApp.windows.first(where: { $0.windowController is MainWindowController })?.windowController as? MainWindowController {
            for (name, image) in main.debugRenderPieces() {
                guard let cg = image, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
                try? png.write(to: URL(filePath: dir).appending(path: "\(suffix)-\(name).png"))
            }
        }
        for (n, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let frameView = window.contentView?.superview,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { continue }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let url = URL(filePath: dir).appending(path: "\(suffix)-\(n).png")
            try? png.write(to: url)
        }
    }

    /// A fresh, isolated data directory; never the real Application Support one.
    static func seedDirectory() throws -> URL {
        let dir = WAKit.cacheDirectory.appending(path: "dev-seed", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Feeds `SessionService` the events that put it into the requested state.
    @MainActor
    static func applyForcedOnboarding(_ name: String, to session: SessionService) -> OnboardingModel.Method {
        switch name {
        case "phone":
            session.handle(.pairing(.qr(code: Seed.sampleQR, timeoutSecs: 60)))
            return .phoneEntry
        case "code":
            session.handle(.pairing(.pairCode(code: "K7Q29XMD", timeoutSecs: 120)))
            return .code
        case "syncing":
            session.handle(.pairing(.success(jid: Seed.me, pushName: "Me")))
            return .qr
        case "loggedout":
            session.handle(.pairing(.loggedOut(reason: "This device was removed from Linked Devices.")))
            return .qr
        default:
            session.handle(.pairing(.qr(code: Seed.sampleQR, timeoutSecs: 60)))
            return .qr
        }
    }
}

/// Synthetic chats, contacts and messages pushed through WAKit's ingest exactly as bridge history
/// chunks would be, so the list exercises the real query and observation path.
enum Seed {
    static let me = "15550000000@s.whatsapp.net"
    static let sampleQR = "2@AbCdEfGhIjKlMnOpQrStUvWxYz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnop,BASE64PUBLICKEY==,BASE64IDENTITY==,SAMPLE=="

    private static let firstNames = ["Aarav", "Priya", "Liam", "Olivia", "Noah", "Emma", "Mateo", "Sofia", "Kenji", "Yuki", "Fatima", "Omar",
                                     "Chloé", "Lucas", "Amara", "Ravi", "Isla", "Hugo", "Zara", "Ethan", "Mei", "Diego", "Nadia", "Felix"]
    private static let lastNames = ["Sharma", "Patel", "Nguyen", "Garcia", "Müller", "Rossi", "Tanaka", "Okafor", "Kowalski", "Haddad",
                                    "Silva", "Andersson", "Dubois", "Kim", "Ivanova", "Mendes"]
    private static let groupNames = ["Weekend Hikers", "Family", "Design Team", "Apartment 4B", "Book Club", "Football Sundays",
                                     "Trip to Lisbon 🇵🇹", "Product Launch", "College Friends", "Neighbourhood Watch", "Parents 2026", "Chess Club"]
    private static let sentences = [
        "Are we still on for tonight?", "Sent you the document, let me know what you think.", "Haha that's brilliant",
        "Running 10 minutes late, sorry!", "Can you call me when you're free?", "Happy birthday!! 🎉", "ok", "👍",
        "Did you see the game last night?", "The meeting moved to 3pm.", "Thanks so much for your help today, really appreciate it.",
        "Where should we meet?", "I'll bring the cake.", "Let's do it next week instead", "Just landed ✈️", "Check this out",
        "This is a much longer message that should wrap onto a second line in the chat list preview so we can see how truncation looks.",
        "lol", "See you soon", "Reminder: rent is due on the 1st", "What's the wifi password again?",
    ]
    private static let captions = ["", "", "Look at this!", "From yesterday", "🔥", "For the report"]

    static let newContactNames = ["Quinn Harper", "Quincy Adeyemi", "Rosa Lindqvist"]
    static func newContactJid(_ n: Int) -> String { "1555999000\(n)@s.whatsapp.net" }

    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    struct Person {
        let jid: String
        let name: String
        let pushName: String
    }

    static func people(_ count: Int, rng: inout RNG) -> [Person] {
        (0..<count).map { i in
            let first = firstNames.randomElement(using: &rng)!
            let last = lastNames.randomElement(using: &rng)!
            let number = String(15_551_000_000 + i)
            return Person(jid: "\(number)@s.whatsapp.net", name: "\(first) \(last)", pushName: first)
        }
    }

    /// Ingests `count` chats in history-style chunks, then flips the session to `ready`.
    static func populate(_ client: WAClient, count: Int) async throws {
        var rng = RNG(state: 42)
        let now = Int64(Date().timeIntervalSince1970)
        let people = people(count, rng: &rng)
        var chats: [BridgeChat] = []
        var contacts: [BridgeContact] = []
        var messages: [BridgeMessage] = []
        var groups: [BridgeGroup] = []

        for i in 0..<count {
            let isGroup = i % 5 == 3
            let jid = isGroup ? "1203630000\(String(format: "%08d", i))@g.us" : people[i].jid
            // Recent activity is dense, older activity sparse.
            let ageSecs = Int64(pow(Double.random(in: 0...1, using: &rng), 2.2) * 60 * 86_400)
            let activity = now - ageSecs - Int64(i % 60)
            let unread = Double.random(in: 0...1, using: &rng) < 0.18 ? UInt32.random(in: 1...14, using: &rng) : 0
            let pinned: Int64? = i < 3 ? now - Int64(i) : nil
            let muted: Int64? = Double.random(in: 0...1, using: &rng) < 0.1 ? Int64.max : nil
            let archived = i > 10 && Double.random(in: 0...1, using: &rng) < 0.08
            let markedUnread = unread == 0 && Double.random(in: 0...1, using: &rng) < 0.02

            if isGroup {
                let name = groupNames[i % groupNames.count] + (i >= groupNames.count * 5 ? " \(i / groupNames.count)" : "")
                chats.append(BridgeChat(jid: jid, kind: .group, name: name, lastActivityAt: activity, unreadCount: unread,
                                        markedUnread: markedUnread, pinnedAt: pinned, mutedUntil: muted, archived: archived, readOnly: false))
                groups.append(BridgeGroup(jid: jid, subject: name, participantCount: UInt32.random(in: 3...48, using: &rng), participants: []))
            } else {
                let p = people[i]
                let saved = Double.random(in: 0...1, using: &rng) < 0.8
                contacts.append(BridgeContact(jid: p.jid, fullName: saved ? p.name : nil, firstName: nil, pushName: p.pushName,
                                              phone: String(p.jid.prefix { $0 != "@" })))
                chats.append(BridgeChat(jid: jid, kind: .dm, name: nil, lastActivityAt: activity, unreadCount: unread,
                                        markedUnread: markedUnread, pinnedAt: pinned, mutedUntil: muted, archived: archived, readOnly: false))
            }
            let sender = isGroup ? people[Int.random(in: 0..<count, using: &rng)] : people[i]
            messages.append(message(id: "SEED\(i)", chat: jid, sender: sender, isGroup: isGroup, ts: activity, rng: &rng))
        }

        // Saved contacts with no chat yet, for ⌘N → start a DM.
        for (n, name) in newContactNames.enumerated() {
            contacts.append(BridgeContact(jid: newContactJid(n), fullName: name, firstName: nil, pushName: nil,
                                          phone: String(newContactJid(n).prefix { $0 != "@" })))
        }

        let chunkSize = 200
        var events: [BridgeEvent] = []
        for start in stride(from: 0, to: count, by: chunkSize) {
            let end = min(start + chunkSize, count)
            events.append(.historyChunk(chunk: BridgeHistoryChunk(
                syncType: .recent, chunkOrder: UInt32(start / chunkSize), progress: UInt32(end * 100 / count),
                chats: Array(chats[start..<end]), messages: Array(messages[start..<end]), updates: [],
                contacts: Array(contacts.filter { c in chats[start..<end].contains { $0.jid == c.jid } })
                    + (start == 0 ? contacts.filter { $0.jid.hasPrefix("1555999") } : []),
                aliases: [], isLastInPayload: end == count)))
        }
        events.append(contentsOf: groups.map { BridgeEvent.group(group: $0) })
        events.append(.ownJid(pn: me, lid: nil))
        try await client.ingest.apply(events)
        await MainActor.run { client.session.handle([.ownJid(pn: me, lid: nil), .connection(.connected)]) }
    }

    private static func message(id: String, chat: String, sender: Person, isGroup: Bool, ts: Int64, rng: inout RNG) -> BridgeMessage {
        let fromMe = Double.random(in: 0...1, using: &rng) < 0.4
        let roll = Double.random(in: 0...1, using: &rng)
        let kind: MessageKind = roll < 0.72 ? .text : roll < 0.82 ? .image : roll < 0.87 ? .voice : roll < 0.91 ? .video
            : roll < 0.94 ? .document : roll < 0.96 ? .sticker : roll < 0.98 ? .location : .poll
        let text: String? = switch kind {
        case .text: sentences.randomElement(using: &rng)
        case .image, .video, .document: captions.randomElement(using: &rng).flatMap { $0.isEmpty ? nil : $0 }
        default: nil
        }
        let media: BridgeMedia? = [.image, .video, .voice, .document, .sticker].contains(kind) ? BridgeMedia(
            directPath: "/v/seed/\(id)", mediaKey: Data(repeating: 1, count: 32), fileSha256: Data(id.utf8) + Data(repeating: 0, count: 32),
            fileEncSha256: Data(repeating: 2, count: 32), fileLength: 12_345, mediaType: kind == .voice ? .audio : kind == .sticker ? .sticker : kind == .document ? .document : kind == .video ? .video : .image,
            mimetype: nil, fileName: kind == .document ? "Q3 report.pdf" : nil, width: nil, height: nil, durationSecs: nil,
            jpegThumbnail: nil, waveform: nil, pageCount: nil, isAnimated: nil) : nil
        return BridgeMessage(
            id: id, chatJid: chat, senderJid: fromMe ? me : sender.jid, participant: isGroup ? (fromMe ? me : sender.jid) : nil,
            fromMe: fromMe, timestamp: ts, kind: kind, text: text, quoted: nil, media: media, location: nil, contact: nil,
            poll: nil, reactions: [], typeName: nil, pushName: fromMe ? nil : sender.pushName,
            status: fromMe ? .read : nil, isForwarded: false, revoked: false, editedAt: nil)
    }

    /// Simulates live traffic: a new message every couple of seconds into a recent chat, with a
    /// typing indicator first.
    @MainActor
    static func runLiveTraffic(_ client: WAClient, window: MainWindowController, count: Int) async {
        var rng = RNG(state: 7)
        let people = people(count, rng: &rng)
        var seq = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2...4, using: &rng)))
            let items = window.visibleChatJids(limit: 40)
            guard let jid = items.randomElement(using: &rng) else { continue }
            let isGroup = jid.hasSuffix("@g.us")
            let sender = people[Int.random(in: 0..<people.count, using: &rng)]
            window.setTyping(chatJid: jid, true)
            try? await Task.sleep(for: .seconds(1.5))
            seq += 1
            let m = message(id: "LIVE\(seq)", chat: jid, sender: sender, isGroup: isGroup, ts: Int64(Date().timeIntervalSince1970), rng: &rng)
            window.setTyping(chatJid: jid, false)
            try? await client.ingest.apply([.messages(messages: [m], updates: [])])
        }
    }
}

extension NSMenuItem {
    func with(tag: Int) -> NSMenuItem {
        self.tag = tag
        return self
    }
}
#endif
