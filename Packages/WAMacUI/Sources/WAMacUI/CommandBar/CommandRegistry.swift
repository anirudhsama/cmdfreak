import AppKit
import WAKit

/// What an action can act on: the chat selected in the main window when the bar opened.
@MainActor
public struct CommandContext {
    public var chat: ChatListItem?
}

/// One command-bar action. Matched against `title` and `keywords`; `shortcut` is display only.
@MainActor
public struct CommandAction: Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    public let keywords: [String]
    public let shortcut: String?
    /// Run after the bar has closed, with the main window it was opened over.
    public let perform: @MainActor (NSWindow?) -> Void

    public init(id: String, title: String, symbol: String, keywords: [String] = [], shortcut: String? = nil,
                perform: @escaping @MainActor (NSWindow?) -> Void) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.keywords = keywords
        self.shortcut = shortcut
        self.perform = perform
    }

    /// An action that sends `selector` down the main window's responder chain, exactly as its menu
    /// item does (falling back to the app-level chain, e.g. for the app delegate's Log Out).
    /// `tag` stands in for the menu item's tag (rail position, pinned index).
    public static func menu(_ id: String, _ title: String, symbol: String, keywords: [String] = [],
                            shortcut: String? = nil, tag: Int = 0, _ selector: Selector) -> CommandAction {
        CommandAction(id: id, title: title, symbol: symbol, keywords: keywords, shortcut: shortcut) { window in
            let sender = NSMenuItem()
            sender.tag = tag
            if window?.firstResponder?.tryToPerform(selector, with: sender) == true { return }
            NSApp.sendAction(selector, to: nil, from: sender)
        }
    }
}

/// Providers of command-bar actions. Each provider sees the current context and returns the
/// actions that apply; add one with `register` to extend the bar.
@MainActor
public final class CommandRegistry {
    public typealias Provider = @MainActor (CommandContext) -> [CommandAction]

    /// `.chat` actions act on the open chat; the bar lists them first.
    public enum Group: Sendable { case chat, general }

    private var providers: [(Group, Provider)] = []

    public init() {}

    public func register(_ group: Group = .general, _ provider: @escaping Provider) {
        providers.append((group, provider))
    }

    public func actions(for context: CommandContext) -> [CommandAction] {
        groupedActions(for: context).map(\.action)
    }

    func groupedActions(for context: CommandContext) -> [(action: CommandAction, group: Group)] {
        providers.flatMap { group, provider in provider(context).map { ($0, group) } }
    }

    /// The v1 set: chat actions on the current chat, navigation, and account.
    static func standard() -> CommandRegistry {
        let registry = CommandRegistry()
        // Least disruptive first: with nothing typed the first one is selected.
        registry.register(.chat) { context in
            guard let chat = context.chat?.chat else { return [] }
            let unread = chat.unreadCount > 0 || chat.markedUnread
            return [
                .menu("chat.attach", "Attach File…", symbol: "paperclip", keywords: ["attach", "send file", "upload"],
                      shortcut: "⇧⌘O", #selector(MainWindowController.attachFile(_:))),
                .menu("chat.unread", unread ? "Mark as Read" : "Mark as Unread", symbol: unread ? "envelope.open" : "envelope.badge",
                      keywords: ["unread", "read"], shortcut: "⇧⌘U", #selector(MainWindowController.toggleUnread(_:))),
                .menu("chat.pin", chat.isPinned ? "Unpin Chat" : "Pin Chat", symbol: chat.isPinned ? "pin.slash" : "pin",
                      keywords: ["pin", "favorite"], shortcut: "⇧⌘P", #selector(MainWindowController.togglePin(_:))),
                .menu("chat.mute", chat.isMuted() ? "Unmute Chat" : "Mute Chat", symbol: chat.isMuted() ? "bell" : "bell.slash",
                      keywords: ["mute", "silence", "notifications"], shortcut: "⇧⌘M", #selector(MainWindowController.toggleMute(_:))),
                .menu("chat.archive", chat.archived ? "Unarchive Chat" : "Archive Chat", symbol: chat.archived ? "tray.and.arrow.up" : "archivebox",
                      keywords: ["archive", "hide"], shortcut: "⇧⌘A", #selector(MainWindowController.toggleArchive(_:))),
            ]
        }
        registry.register { _ in
            [
                .menu("go.newChat", "New Chat", symbol: "square.and.pencil", keywords: ["new", "start", "message", "contact"],
                      shortcut: "⌘N", #selector(MainWindowController.newChat(_:))),
                .menu("go.nextUnread", "Next Unread Chat", symbol: "arrow.down.circle", keywords: ["unread", "jump"],
                      shortcut: "⌥↓", #selector(MainWindowController.nextUnreadChat(_:))),
                .menu("go.chats", "Show Chats", symbol: "bubble.left.and.bubble.right", keywords: ["inbox", "all chats"],
                      shortcut: "⌥⌘1", tag: 1, #selector(MainWindowController.selectRailItem(_:))),
                .menu("go.unread", "Show Unread Chats", symbol: "message.badge", keywords: ["unread", "filter"],
                      shortcut: "⌥⌘2", tag: 2, #selector(MainWindowController.selectRailItem(_:))),
                .menu("go.groups", "Show Groups", symbol: "person.2", keywords: ["groups", "filter"],
                      shortcut: "⌥⌘3", tag: 3, #selector(MainWindowController.selectRailItem(_:))),
                .menu("go.businesses", "Show Businesses", symbol: "building.2", keywords: ["business", "shops", "filter"],
                      shortcut: "⌥⌘4", tag: 4, #selector(MainWindowController.selectRailItem(_:))),
                .menu("go.archived", "Show Archived Chats", symbol: "archivebox", keywords: ["archived"],
                      shortcut: "⌥⌘5", tag: 5, #selector(MainWindowController.selectRailItem(_:))),
                .menu("view.sidebar", "Toggle Sidebar", symbol: "sidebar.left", keywords: ["sidebar", "hide list"],
                      shortcut: "⌃⌘S", #selector(NSSplitViewController.toggleSidebar(_:))),
                .menu("app.logout", "Log Out…", symbol: "rectangle.portrait.and.arrow.right", keywords: ["sign out", "unlink", "logout"],
                      Selector(("logOut:"))),
            ]
        }
        return registry
    }
}
