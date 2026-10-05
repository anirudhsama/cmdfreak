#if DEBUG
import AppKit
import Synchronization
import UniformTypeIdentifiers
import WAKit

/// Debug-only stand-alone chat window. `CMDFREAK_CHAT_HARNESS=1` (DM first) or `=group` seeds a
/// throwaway database under `Application Support/CmdFreak/harness/` and mounts `ChatViewController`
/// without the shell. ⌘1 / ⌘2 switch between the seeded DM and group; typing "ping" gets a reply.
@MainActor
public enum ChatHarness {
    nonisolated static let dm = "15551110000@s.whatsapp.net"
    nonisolated static let group = "120363000000000001@g.us"
    nonisolated static let me = "15550000000@s.whatsapp.net"
    nonisolated static let bob = "15552220000@s.whatsapp.net"
    nonisolated static let carol = "15553330000@s.whatsapp.net"

    private static var window: NSWindow?
    private static var client: WAClient?
    private static var controller: ChatViewController?
    private static var monitor: Any?

    /// Returns true when the harness took over launch; the caller should skip its normal window.
    public static func launchIfRequested() -> Bool {
        guard let mode = ProcessInfo.processInfo.environment["CMDFREAK_CHAT_HARNESS"], !mode.isEmpty, mode != "0" else { return false }
        do {
            try launch(startWithGroup: mode == "group")
        } catch {
            NSLog("harness failed: \(error)")
        }
        return true
    }

    private static func launch(startWithGroup: Bool) throws {
        let root = WAKit.dataDirectory.appending(path: "harness", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root.appending(path: "remote"), withIntermediateDirectories: true)
        let database = try AppDatabase(url: root.appending(path: "app.sqlite"))
        try database.pool.write { db in
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('ownPn', ?)", arguments: [me])
        }
        let bridge = HarnessBridge(remoteDir: root.appending(path: "remote"))
        let client = try WAClient(database: database) { sink in
            bridge.sink = sink
            return bridge
        }
        self.client = client

        let vc = ChatViewController(client: client)
        controller = vc

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Chat harness"
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "harness")
        vc.view.frame = NSRect(x: 0, y: 0, width: 860, height: 720)
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 860, height: 720))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        HarnessCommands.start(window: window, controller: vc) { open($0) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers {
            case "1": open(dm); return nil
            case "2": open(group); return nil
            case "d": NSApp.appearance = NSApp.appearance == nil ? NSAppearance(named: .darkAqua) : nil; return nil
            default: return event
            }
        }

        Task<Void, Never> {
            let seed = await Task.detached(priority: .userInitiated) { try Seed.build(remoteDir: root.appending(path: "remote")) }.result
            do {
                let events = try seed.get()
                try await client.ingest.apply(events)
                open(startWithGroup ? group : dm)
            } catch {
                NSLog("harness seed failed: \(error)")
            }
        }
    }

    private static func open(_ jid: String) {
        guard let vc = controller else { return }
        window?.title = jid == dm ? "Alice Example" : "Design Team"
        window?.subtitle = jid == dm ? "+1 (555) 111-0000" : "Alice, Bob, Carol, You"
        Task { await vc.open(chatJid: jid) }
    }

    /// Simulates the other side: a live incoming message through the same path real events take.
    static func deliverIncoming(text: String, chat: String) {
        guard let bridge = client?.bridge as? HarnessBridge else { return }
        let ts = Int64(Date().timeIntervalSince1970)
        _ = bridge.sink?.onEvents(events: [.messages(messages: [Seed.message("live-\(ts)-\(text.hashValue)", chat: chat, sender: chat == dm ? dm : bob,
                                                                  ts: ts, text: text, pushName: chat == dm ? nil : "Bob", status: nil)], updates: [])])
    }
}

/// `WaBridgeProtocol` stub: sends succeed after a delay (or fail when the text contains "fail"),
/// downloads copy from the remote directory, everything else is a no-op.
final class HarnessBridge: WaBridgeProtocol, @unchecked Sendable {
    let remoteDir: URL
    var sink: (any EventSink)?
    private let failedOnce = Mutex(Set<String>())

    init(remoteDir: URL) { self.remoteDir = remoteDir }

    func archiveChat(chat: String, archived: Bool) async throws {}
    func cancelPairing() async throws {}
    func connect() async throws {}
    func dataDir() -> String { remoteDir.path }
    func disconnect() async throws {}
    func downloadMedia(media: BridgeMedia, destPath: String, progress: (any ProgressSink)?) async throws {
        let src = remoteDir.appending(path: media.fileSha256.map { String(format: "%02x", $0) }.joined())
        guard FileManager.default.fileExists(atPath: src.path) else { throw BridgeError.NotFound("no remote file") }
        for step in 1...6 {
            try await Task.sleep(for: .milliseconds(120))
            progress?.onProgress(done: UInt64(step), total: 6)
        }
        try FileManager.default.copyItem(at: src, to: URL(filePath: destPath))
    }
    func editMessage(target: BridgeMessageKey, text: String, mentions: [String]) async throws {}
    func listParticipatingGroups() async throws -> [String] { [] }
    func fetchGroupMetadata(jid: String) async throws -> BridgeGroup { BridgeGroup(jid: jid, subject: "Design Team", participantCount: 4, participants: []) }
    func fetchGroupOverviews(jids: [String]) async throws -> [BridgeGroup] { [] }
    func checkBusiness(jids: [String]) async throws -> [BridgeBusinessCheck] { [] }
    func importCapture(captureDir: String) async throws {}
    func logout() async throws {}
    func markChatRead(chat: String, read: Bool) async throws {}
    func markRead(chat: String, messages: [BridgeMessageKey]) async throws {}
    func muteChat(chat: String, until: Int64?) async throws {}
    func nudgeReconnect() {}
    func pairWithPhone(number: String) async throws -> String { "ABCD-EFGH" }
    func pinChat(chat: String, pinned: Bool) async throws {}
    func profilePicture(jid: String, commonGid: String?, preview: Bool, destPath: String) async throws -> Bool { false }
    func revokeMessage(target: BridgeMessageKey) async throws {}
    func sendChatState(chat: String, state: ChatState) async throws { NSLog("harness: chat state \(state)") }
    func sendMedia(chat: String, media: BridgeOutgoingMedia, replyTo: BridgeMessageKey?, messageId: String?, progress: (any ProgressSink)?) async throws -> BridgeSendResult {
        let data = try Data(contentsOf: URL(filePath: media.filePath))
        let total = UInt64(data.count)
        for step in 0...20 {
            progress?.onProgress(done: total * UInt64(step) / 20, total: total)
            try await Task.sleep(for: .milliseconds(90))
            // "fail" in the caption fails the first attempt only, so retry can be exercised.
            if step == 12, media.caption?.localizedCaseInsensitiveContains("fail") == true,
               failedOnce.withLock({ $0.insert(media.filePath).inserted }) {
                throw BridgeError.Network("harness: simulated upload failure")
            }
        }
        let kind: MessageKind = switch media.kind {
        case .image: .image
        case .video: .video
        case .gif: .gif
        case .document: .document
        }
        let type: BridgeMediaType = switch media.kind {
        case .image: .image
        case .video, .gif: .video
        case .document: .document
        }
        let m = try Seed.media(data, remoteDir: remoteDir, type: type, mime: media.mimetype, name: media.fileName,
                               width: media.width.map(Int.init), height: media.height.map(Int.init), duration: media.durationSecs.map(Int.init),
                               thumb: media.jpegThumbnail, pages: media.pageCount.map(Int.init), animated: media.kind == .gif ? true : nil)
        let ts = Int64(Date().timeIntervalSince1970)
        let id = messageId ?? "SRV-" + UUID().uuidString.prefix(8)
        ack(id, chat: chat)
        return BridgeSendResult(messageId: id, timestamp: ts,
                                message: Seed.message("x", chat: chat, sender: ChatHarness.me, fromMe: true, ts: ts, kind: kind,
                                                      text: media.caption, media: m, status: .sent))
    }
    /// The server's ack, a moment after the send returns.
    private func ack(_ id: String, chat: String) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [sink] in
            _ = sink?.onEvents(events: [.serverAck(ack: BridgeServerAck(chatJid: chat, messageId: id, error: nil))])
        }
    }
    func sendReaction(target: BridgeMessageKey, emoji: String) async throws {}
    func sendText(chat: String, text: String, mentions: [String], replyTo: BridgeMessageKey?, messageId: String?) async throws -> BridgeSendResult {
        try await Task.sleep(for: .milliseconds(700))
        if text.localizedCaseInsensitiveContains("fail") { throw BridgeError.Network("harness: simulated failure") }
        let ts = Int64(Date().timeIntervalSince1970)
        let id = messageId ?? "SRV-" + UUID().uuidString.prefix(8)
        ack(id, chat: chat)
        if text.lowercased() == "ping" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                ChatHarness.deliverIncoming(text: "pong 🏓", chat: chat)
            }
        }
        return BridgeSendResult(messageId: id, timestamp: ts,
                                message: Seed.message(id, chat: chat, sender: ChatHarness.me, fromMe: true, ts: ts, text: text, status: .sent))
    }
    func startPairingQr() async throws {}
    func stats() -> BridgeStats { BridgeStats(eventsReceived: 0, eventsDropped: 0, batchesFlushed: 0) }
    func subscribePresence(jid: String) async throws {}
}

/// Seed content: one DM with every message kind, one group with 5k text messages.
enum Seed {
    static func message(
        _ id: String, chat: String, sender: String, fromMe: Bool = false, ts: Int64, kind: MessageKind = .text, text: String? = nil,
        media: BridgeMedia? = nil, quoted: BridgeQuoted? = nil, reactions: [BridgeReaction] = [], pushName: String? = nil,
        status: MessageStatus? = .read, revoked: Bool = false, editedAt: Int64? = nil, forwarded: Bool = false,
        location: BridgeLocation? = nil, contact: BridgeContactCard? = nil, poll: BridgePoll? = nil, typeName: String? = nil
    ) -> BridgeMessage {
        BridgeMessage(
            id: id, chatJid: chat, senderJid: sender, participant: chat.hasSuffix("@g.us") ? sender : nil, fromMe: fromMe,
            timestamp: ts, kind: kind, text: text, quoted: quoted, media: media, location: location, contact: contact, poll: poll,
            reactions: reactions, typeName: typeName, pushName: pushName, status: status, isForwarded: forwarded, revoked: revoked, editedAt: editedAt)
    }

    static func media(_ data: Data, remoteDir: URL, type: BridgeMediaType, mime: String, name: String? = nil, width: Int? = nil, height: Int? = nil,
                      duration: Int? = nil, thumb: Data? = nil, waveform: Data? = nil, pages: Int? = nil, animated: Bool? = nil) throws -> BridgeMedia {
        var sha = Data(count: 32)
        var h: UInt64 = 1_469_598_103_934_665_603
        for b in data.prefix(4096) { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        h ^= UInt64(data.count)
        for i in 0..<8 { sha[i] = UInt8((h >> (8 * UInt64(i))) & 0xFF) }
        sha[8] = UInt8(data.count & 0xFF)
        try data.write(to: remoteDir.appending(path: sha.map { String(format: "%02x", $0) }.joined()))
        return BridgeMedia(
            directPath: "/v/harness/\(name ?? mime)", mediaKey: Data(repeating: 1, count: 32), fileSha256: sha, fileEncSha256: sha,
            fileLength: UInt64(data.count), mediaType: type, mimetype: mime, fileName: name, width: width.map(UInt32.init),
            height: height.map(UInt32.init), durationSecs: duration.map(UInt32.init), jpegThumbnail: thumb, waveform: waveform,
            pageCount: pages.map(UInt32.init), isAnimated: animated)
    }

    static func build(remoteDir: URL) throws -> [BridgeEvent] {
        let dm = ChatHarness.dm, group = ChatHarness.group, me = ChatHarness.me, bob = ChatHarness.bob, carol = ChatHarness.carol
        let now = Int64(Date().timeIntervalSince1970)
        let day: Int64 = 86_400
        var t = now - 3 * day
        func next(_ gap: Int64 = 90) -> Int64 { t += gap; return t }

        // Media files
        let img1 = HarnessMedia.image(size: CGSize(width: 1200, height: 900), hue: 0.55, label: "Harbour")
        let img2 = HarnessMedia.image(size: CGSize(width: 800, height: 1200), hue: 0.05, label: "Portrait")
        let img3 = HarnessMedia.image(size: CGSize(width: 1600, height: 500), hue: 0.33, label: "Panorama")
        let photo1 = try media(HarnessMedia.encode(img1, type: .jpeg), remoteDir: remoteDir, type: .image, mime: "image/jpeg", width: 1200, height: 900, thumb: HarnessMedia.thumbnail(img1))
        let photo2 = try media(HarnessMedia.encode(img2, type: .jpeg), remoteDir: remoteDir, type: .image, mime: "image/jpeg", width: 800, height: 1200, thumb: HarnessMedia.thumbnail(img2))
        let photo3 = try media(HarnessMedia.encode(img3, type: .jpeg), remoteDir: remoteDir, type: .image, mime: "image/jpeg", width: 1600, height: 500, thumb: HarnessMedia.thumbnail(img3))
        let stickerData = HarnessMedia.sticker(hue: 0.12)
        let sticker = try media(stickerData, remoteDir: remoteDir, type: .sticker, mime: "image/webp", width: 512, height: 512, animated: false)
        let videoURL = remoteDir.appending(path: "clip.mp4")
        try HarnessMedia.video(to: videoURL)
        let videoData = try Data(contentsOf: videoURL)
        let videoThumb = HarnessMedia.thumbnail(HarnessMedia.image(size: CGSize(width: 480, height: 360), hue: 0.6, label: ""))
        let video = try media(videoData, remoteDir: remoteDir, type: .video, mime: "video/mp4", width: 480, height: 360, duration: 2, thumb: videoThumb)
        let gif = try media(videoData + Data([0]), remoteDir: remoteDir, type: .video, mime: "video/mp4", width: 480, height: 360, duration: 2, thumb: videoThumb, animated: true)
        let pdfURL = remoteDir.appending(path: "doc.pdf")
        HarnessMedia.pdf(to: pdfURL, pages: 3)
        let doc = try media(try Data(contentsOf: pdfURL), remoteDir: remoteDir, type: .document, mime: "application/pdf", name: "Q3 planning notes.pdf", pages: 3)
        let cafURL = remoteDir.appending(path: "voice.caf")
        try HarnessMedia.audio(to: cafURL)
        let voice = try media(try Data(contentsOf: cafURL), remoteDir: remoteDir, type: .audio, mime: "audio/x-caf", name: "voice.caf", duration: 3, waveform: HarnessMedia.waveform())
        let audio = try media(try Data(contentsOf: cafURL) + Data([0]), remoteDir: remoteDir, type: .audio, mime: "audio/x-caf", name: "Song sketch.caf", duration: 3)

        var msgs: [BridgeMessage] = []
        func add(_ m: BridgeMessage) { msgs.append(m) }
        var n = 0
        func id() -> String { n += 1; return "dm-\(n)" }

        add(message(id(), chat: dm, sender: dm, ts: next(), text: "Hey! Landed safely, the flight was *smooth* and the view was _incredible_ 🌅"))
        add(message(id(), chat: dm, sender: me, fromMe: true, ts: next(), text: "That's great to hear. Send pics when you can!", status: .read))
        add(message(id(), chat: dm, sender: dm, ts: next(), kind: .image, media: photo1))
        add(message(id(), chat: dm, sender: dm, ts: next(30), kind: .image, text: "The harbour at sunrise. ~Not~ a filter, promise.", media: photo2))
        add(message(id(), chat: dm, sender: me, fromMe: true, ts: next(), text: "😍", reactions: [BridgeReaction(senderJid: dm, fromMe: false, emoji: "❤️", timestamp: t)], status: .read))
        add(message(id(), chat: dm, sender: dm, ts: next(), kind: .sticker, media: sticker))
        add(message(id(), chat: dm, sender: dm, ts: next(day), kind: .video, text: "Short clip from the boat", media: video))
        add(message(id(), chat: dm, sender: dm, ts: next(30), kind: .gif, media: gif))
        add(message(id(), chat: dm, sender: me, fromMe: true, ts: next(), kind: .document, media: doc, status: .delivered))
        add(message(id(), chat: dm, sender: dm, ts: next(), kind: .voice, media: voice))
        add(message(id(), chat: dm, sender: dm, ts: next(), kind: .audio, media: audio))
        add(message(id(), chat: dm, sender: dm, ts: next(), kind: .location,
                    location: BridgeLocation(latitude: 41.3851, longitude: 2.1734, name: "Barceloneta Beach", address: "Passeig Marítim, Barcelona", isLive: false)))
        add(message(id(), chat: dm, sender: me, fromMe: true, ts: next(), kind: .contact, status: .read,
                    contact: BridgeContactCard(displayName: "Dr. Maria Costa", vcard: "BEGIN:VCARD\nFN:Dr. Maria Costa\nEND:VCARD")))
        add(message(id(), chat: dm, sender: dm, ts: next(), kind: .poll, text: "Dinner on Friday?",
                    poll: BridgePoll(question: "Dinner on Friday?", options: ["Tapas", "Sushi", "Pizza"], selectableCount: 1)))
        let pollId = "dm-\(n)"
        add(message(id(), chat: dm, sender: dm, ts: next(), kind: .system, text: "Messages and calls are end-to-end encrypted.", typeName: "e2e"))
        add(message(id(), chat: dm, sender: dm, ts: next(), kind: .undecryptable))
        add(message(id(), chat: dm, sender: dm, ts: next(), kind: .unsupported, typeName: "interactiveMessage"))
        add(message(id(), chat: dm, sender: me, fromMe: true, ts: next(), text: "oops wrong chat", status: .read, revoked: true))
        add(message(id(), chat: dm, sender: dm, ts: next(), text: "Check https://developer.apple.com/documentation/appkit and call me at +1 415 555 0199 when you land. Code: `git rebase -i HEAD~3`", editedAt: t))
        add(message(id(), chat: dm, sender: dm, ts: next(), text: "```\nfunc hello() {\n    print(\"hi\")\n}\n```"))
        add(message(id(), chat: dm, sender: me, fromMe: true, ts: next(day), text: "Replying to your poll — Tapas for sure",
                    quoted: BridgeQuoted(id: pollId, senderJid: dm, kind: .poll, snippet: "Dinner on Friday?"), status: .read))
        add(message(id(), chat: dm, sender: dm, ts: next(), text: "Deal 🙌", quoted: BridgeQuoted(id: "dm-2", senderJid: me, kind: .text, snippet: "That's great to hear. Send pics when you can!"),
                    reactions: [BridgeReaction(senderJid: me, fromMe: true, emoji: "👍", timestamp: t), BridgeReaction(senderJid: dm, fromMe: false, emoji: "👍", timestamp: t)]))
        add(message(id(), chat: dm, sender: dm, ts: next(), text: "Forwarding the itinerary as promised", forwarded: true))
        add(message(id(), chat: dm, sender: dm, ts: next(20), kind: .image, media: photo3))
        add(message(id(), chat: dm, sender: dm, ts: next(20), text: String(repeating: "This is a deliberately long message to check wrapping, meta placement below the last line, and bubble max width. ", count: 3)))
        add(message(id(), chat: dm, sender: me, fromMe: true, ts: next(), text: "Sent ✓", status: .sent))
        add(message(id(), chat: dm, sender: me, fromMe: true, ts: next(5), text: "Delivered ✓✓", status: .delivered))
        add(message(id(), chat: dm, sender: me, fromMe: true, ts: next(5), text: "Read (blue)", status: .read))
        add(message(id(), chat: dm, sender: me, fromMe: true, ts: next(5), text: "Still sending…", status: .pending))
        add(message(id(), chat: dm, sender: me, fromMe: true, ts: next(5), text: "This one failed", status: .failed))
        add(message(id(), chat: dm, sender: dm, ts: next(600), text: "👍🏽"))
        add(message(id(), chat: dm, sender: dm, ts: next(10), text: "Unread from here on"))
        add(message(id(), chat: dm, sender: dm, ts: next(10), text: "Try typing *ping* and I will answer. Type a message containing \"fail\" to see a failed send."))

        // Group: 5k messages, four senders, replies sprinkled in.
        let senders: [(String, String?)] = [(ChatHarness.dm, "Alice"), (bob, "Bob"), (carol, "Carol"), (me, nil)]
        let lines = ["Morning all", "Pushed the new build to TestFlight", "Can someone review PR #482?", "On it", "The spacing on the sidebar looks off in dark mode",
                     "Agreed, I'll take a look after lunch", "Standup in 5", "🚀", "Let's ship it", "Draft of the launch copy is in Notion", "lgtm",
                     "Should we use *semantic colors* everywhere?", "Yes, no hard-coded hex", "Merged", "Anyone up for coffee? ☕️", "Design review moved to 3pm"]
        var gt = now - 60 * day
        var gmsgs: [BridgeMessage] = []
        var lastId = ""
        for i in 0..<5000 {
            let (s, name) = senders[(i * 7 + i / 3) % senders.count]
            gt += Int64(20 + (i * 37) % 900)
            let gid = "g-\(i)"
            var quoted: BridgeQuoted?
            if i % 41 == 0, !lastId.isEmpty { quoted = BridgeQuoted(id: lastId, senderJid: senders[(i - 1) % senders.count].0, kind: .text, snippet: lines[(i - 1) % lines.count]) }
            let reactions = i % 23 == 0 ? [BridgeReaction(senderJid: bob, fromMe: false, emoji: "🔥", timestamp: gt)] : []
            gmsgs.append(message(gid, chat: group, sender: s, fromMe: s == me, ts: gt, text: "\(lines[i % lines.count]) (#\(i))",
                                 quoted: quoted, reactions: reactions, pushName: name, status: s == me ? .read : .delivered))
            lastId = gid
        }
        gmsgs.append(message("g-sys", chat: group, sender: bob, ts: gt + 60, kind: .system, text: "Carol added Dan", typeName: "add"))

        let chats = [
            BridgeChat(jid: dm, kind: .dm, name: "Alice Example", lastActivityAt: t, unreadCount: 2, markedUnread: false, pinnedAt: nil, mutedUntil: nil, archived: false, readOnly: false),
            BridgeChat(jid: group, kind: .group, name: "Design Team", lastActivityAt: gt, unreadCount: 0, markedUnread: false, pinnedAt: nil, mutedUntil: nil, archived: false, readOnly: false),
        ]
        let contacts = [
            BridgeContact(jid: dm, fullName: "Alice Example", firstName: "Alice", pushName: "Alice", phone: "15551110000"),
            BridgeContact(jid: bob, fullName: "Bob Stone", firstName: "Bob", pushName: "Bob", phone: "15552220000"),
            BridgeContact(jid: carol, fullName: "Carol Reyes", firstName: "Carol", pushName: "Carol", phone: "15553330000"),
        ]
        let updates: [BridgeMessageUpdate] = [
            .pollVote(target: BridgeMessageKey(chatJid: dm, id: pollId, fromMe: false, participant: nil), voterJid: me, selected: ["Tapas"], timestamp: t),
            .pollVote(target: BridgeMessageKey(chatJid: dm, id: pollId, fromMe: false, participant: nil), voterJid: dm, selected: ["Sushi"], timestamp: t),
        ]
        return [.historyChunk(chunk: BridgeHistoryChunk(
            syncType: .recent, chunkOrder: 0, progress: 100, chats: chats, messages: msgs + gmsgs, updates: updates,
            contacts: contacts, aliases: [], isLastInPayload: true))]
    }
}
#endif
