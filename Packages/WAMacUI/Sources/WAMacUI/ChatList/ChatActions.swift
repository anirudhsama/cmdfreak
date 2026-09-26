import AppKit
import WAKit

/// Chat-level actions shared by the menu bar and the row context menu. Each call is optimistic in
/// WAKit; failures are logged, not surfaced, since the local state already changed.
@MainActor
struct ChatActions {
    let client: WAClient

    enum MuteDuration: CaseIterable {
        case eightHours, oneWeek, always

        var title: String {
            switch self {
            case .eightHours: "8 Hours"
            case .oneWeek: "1 Week"
            case .always: "Always"
            }
        }

        var until: Int64 {
            let now = Int64(Date().timeIntervalSince1970)
            switch self {
            case .eightHours: return now + 8 * 3600
            case .oneWeek: return now + 7 * 86_400
            case .always: return .max
            }
        }
    }

    func togglePin(_ chat: ChatRecord) {
        run("pin") { try await client.setPinned(chat.jid, !chat.isPinned) }
    }

    func toggleArchive(_ chat: ChatRecord) {
        run("archive") { try await client.setArchived(chat.jid, !chat.archived) }
    }

    func toggleUnread(_ chat: ChatRecord) {
        let read = chat.unreadCount > 0 || chat.markedUnread
        run("markRead") { try await client.setRead(chat.jid, read) }
    }

    func mute(_ chat: ChatRecord, for duration: MuteDuration) {
        run("mute") { try await client.setMuted(chat.jid, until: duration.until) }
    }

    func unmute(_ chat: ChatRecord) {
        run("unmute") { try await client.setMuted(chat.jid, until: nil) }
    }

    func toggleMute(_ chat: ChatRecord) {
        if chat.isMuted() { unmute(chat) } else { mute(chat, for: .always) }
    }

    /// Context menu for `chat`; the same items the Chat menu offers.
    func contextMenu(for chat: ChatRecord) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem(chat.isPinned ? "Unpin" : "Pin", symbol: chat.isPinned ? "pin.slash" : "pin") { togglePin(chat) })

        if chat.isMuted() {
            menu.addItem(makeItem("Unmute", symbol: "bell") { unmute(chat) })
        } else {
            let muteItem = makeItem("Mute", symbol: "bell.slash") {}
            let submenu = NSMenu()
            for duration in MuteDuration.allCases {
                submenu.addItem(makeItem(duration.title, symbol: nil) { mute(chat, for: duration) })
            }
            muteItem.submenu = submenu
            menu.addItem(muteItem)
        }

        let unread = chat.unreadCount > 0 || chat.markedUnread
        menu.addItem(makeItem(unread ? "Mark as Read" : "Mark as Unread",
                              symbol: unread ? "envelope.open" : "envelope.badge") { toggleUnread(chat) })
        menu.addItem(.separator())
        menu.addItem(makeItem(chat.archived ? "Unarchive" : "Archive",
                              symbol: chat.archived ? "tray.and.arrow.up" : "archivebox") { toggleArchive(chat) })
        return menu
    }

    private func makeItem(_ title: String, symbol: String?, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = BlockMenuItem(title: title, action: action)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func run(_ what: String, _ body: @escaping @Sendable () async throws -> Void) {
        Task {
            do { try await body() } catch { WAKit.log.error("chat action \(what, privacy: .public) failed: \(error)") }
        }
    }
}

/// Menu item that runs a closure; keeps context menus free of selector plumbing.
@MainActor
final class BlockMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
