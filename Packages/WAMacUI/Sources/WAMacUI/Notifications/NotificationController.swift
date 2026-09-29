import AppKit
import UserNotifications
import WAKit

/// Posts a system notification for each incoming message that ingest flags (`WAClient.notices`) and
/// withdraws delivered ones when their chat is read anywhere or the message is deleted, and on launch
/// and activation any whose chat has nothing unread. Clicking one opens the chat; Reply sends from
/// the banner; Mark as Read sends read receipts.
@MainActor
public final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let category = "message"
    private nonisolated static let replyAction = "reply"
    private nonisolated static let markReadAction = "markRead"
    private nonisolated static let chatKey = "chatJid"

    private let client: WAClient
    private let center = UNUserNotificationCenter.current()
    private var listener: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?
    /// Posted this session, per chat: withdrawn directly, since a just-added request may not be in
    /// `deliveredNotifications()` yet. That query still covers earlier sessions.
    private var posted: [String: Set<String>] = [:]
    /// Shows `chatJid` in the main window.
    public var openChat: ((String) -> Void)?

    public init(client: WAClient) {
        self.client = client
        super.init()
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let read = UNNotificationAction(identifier: Self.markReadAction, title: "Mark as Read")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [reply, read], intentIdentifiers: [])])
        // Serial: a withdrawal must not overtake the post it withdraws.
        listener = Task { [weak self, notices = client.notices] in
            for await event in notices {
                guard let self else { return }
                await self.handle(event)
            }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.withdrawStale() }
        }
        withdrawStale()
    }

    isolated deinit {
        listener?.cancel()
        activeObserver.map(NotificationCenter.default.removeObserver)
    }

    /// Asks once; later calls return the stored answer without prompting.
    public func requestAuthorization() {
        Task { [center] in
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) } catch {
                WAKit.log.error("notification authorization failed: \(error)")
            }
        }
    }

    private func handle(_ event: NoticeEvent) async {
        switch event {
        case .incoming(let notice):
            await post(notice)
        case .chatRead(let jid):
            await withdraw(chat: jid)
        case .messageRemoved(let chatJid, let messageId):
            // Under a LID since merged, it is left to `withdrawStale`.
            let id = Self.identifier(chatJid, messageId)
            posted[chatJid]?.remove(id)
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    /// Withdraws `jid`'s notifications, including ones posted under a LID it has since merged from.
    private func withdraw(chat jid: String) async {
        let delivered = await center.deliveredNotifications()
        let threads = Set(delivered.map(\.request.content.threadIdentifier)).union(posted.keys)
        let canonical = await client.ingest.canonicalJids(threads)
        var ids = delivered.filter { canonical[$0.request.content.threadIdentifier] == jid }.map(\.request.identifier)
        for key in posted.keys where canonical[key] == jid {
            ids += posted.removeValue(forKey: key) ?? []
        }
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }

    /// Withdraws notifications whose chat has nothing unread: a safety net for withdrawals no event
    /// covered (a LID merged after posting, events dropped from a full notice buffer).
    /// Removes by identifier, so a notification posted meanwhile is never caught.
    private func withdrawStale() {
        Task { [center, client] in
            let delivered = await center.deliveredNotifications()
            let threads = Set(delivered.map(\.request.content.threadIdentifier))
            guard !threads.isEmpty else { return }
            do {
                let read = try await client.ingest.readChats(among: threads)
                let ids = delivered.filter { read.contains($0.request.content.threadIdentifier) }.map(\.request.identifier)
                if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
            } catch {
                WAKit.log.error("withdraw stale notifications failed: \(error)")
            }
        }
    }

    private func post(_ notice: IncomingNotice) async {
        let content = UNMutableNotificationContent()
        content.title = notice.chatTitle
        content.body = (notice.senderName.map { "\($0): " } ?? "") + Self.body(kind: notice.kind, text: notice.text)
        content.sound = .default
        content.threadIdentifier = notice.chatJid
        content.categoryIdentifier = Self.category
        content.userInfo = [Self.chatKey: notice.chatJid]
        if let avatar = notice.avatarURL.flatMap(Self.avatarAttachment) { content.attachments = [avatar] }
        let request = UNNotificationRequest(identifier: Self.identifier(notice.chatJid, notice.messageId), content: content, trigger: nil)
        do {
            try await center.add(request)
            posted[notice.chatJid, default: []].insert(request.identifier)
        } catch {
            // Not added (e.g. permission denied): the system never took the avatar copy.
            for a in content.attachments { try? FileManager.default.removeItem(at: a.url) }
            WAKit.log.error("post notification failed: \(error)")
        }
    }

    /// The system takes ownership of (moves) an attachment's file, so it gets a temporary copy of the
    /// cached avatar. Shown as a thumbnail beside the text; the app icon stays.
    private static func avatarAttachment(_ url: URL) -> UNNotificationAttachment? {
        let copy = FileManager.default.temporaryDirectory.appending(path: "notification-avatar-\(UUID().uuidString).jpg")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return try UNNotificationAttachment(identifier: "avatar", url: copy)
        } catch {
            try? FileManager.default.removeItem(at: copy)
            return nil
        }
    }

    /// `sendText` records a failure on the message row instead of throwing, so check the row.
    private func send(_ text: String, to chatJid: String) async -> Bool {
        do {
            let localId = try await client.sendText(text, to: chatJid)
            let item = try await client.windowLoader(for: chatJid).items(ids: [localId]).first
            return item?.message.status != .failed
        } catch {
            WAKit.log.error("notification reply failed: \(error)")
            return false
        }
    }

    /// The failed row stays in the chat with its retry control; this says so and leaves the chat unread.
    private func postSendFailure(chatJid: String, text: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Message not sent"
        content.body = text
        content.sound = .default
        content.threadIdentifier = chatJid
        content.userInfo = [Self.chatKey: chatJid]
        let request = UNNotificationRequest(identifier: "\(chatJid)/failed-\(UUID().uuidString)", content: content, trigger: nil)
        do { try await center.add(request) } catch { WAKit.log.error("post notification failed: \(error)") }
    }

    private nonisolated static func identifier(_ chatJid: String, _ messageId: String) -> String { "\(chatJid)/\(messageId)" }

    /// WhatsApp's own wording: the caption (or a label) behind the media kind's emoji.
    nonisolated static func body(kind: MessageKind, text: String?) -> String {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let (emoji, label): (String?, String) = switch kind {
        case .text, .system: (nil, "")
        case .image: ("📷", "Photo")
        case .video: ("🎥", "Video")
        case .gif: ("👾", "GIF")
        case .sticker: (nil, "Sticker")
        case .document: ("📄", "Document")
        case .audio: ("🎵", "Audio")
        case .voice: ("🎤", "Voice message")
        case .location: ("📍", "Location")
        case .contact: ("👤", "Contact")
        case .poll: ("📊", "Poll")
        case .undecryptable: (nil, "Waiting for this message")
        case .unsupported: (nil, "Unsupported message")
        }
        let shown = text.isEmpty ? label : text
        return emoji.map { "\($0) \(shown)" } ?? shown
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Banners also show while the app is frontmost; the open chat never notifies (ingest skips it).
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                  willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                  didReceive response: UNNotificationResponse) async {
        guard let chatJid = response.notification.request.content.userInfo[Self.chatKey] as? String else { return }
        let action = response.actionIdentifier
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        await respond(action: action, chatJid: chatJid, reply: reply)
    }

    private func respond(action: String, chatJid: String, reply: String?) async {
        // Delivered under a LID before an alias merge moved the chat to its phone-number JID.
        let jid = await client.ingest.canonicalJid(chatJid)
        switch action {
        case UNNotificationDefaultActionIdentifier:
            NSApp.activate()
            openChat?(jid)
        case Self.replyAction:
            guard let text = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            if await send(text, to: jid) {
                await client.markRead(jid)
            } else {
                await postSendFailure(chatJid: jid, text: text)
            }
        case Self.markReadAction:
            await client.markRead(jid)
        default:
            break
        }
    }
}
