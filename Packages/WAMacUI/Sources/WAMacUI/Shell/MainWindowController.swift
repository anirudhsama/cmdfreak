import AppKit
import SwiftUI
import WAKit

/// The main window: a split view whose sidebar item holds the rail and chat list (standard sidebar
/// behaviour, so macOS 26 renders it as floating glass) and whose content item is the chat
/// container. Every keyboard shortcut is a menu item whose action lands here via the responder chain.
@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    public let client: WAClient
    public let chatContainer: ChatContainerViewController

    let railModel = RailModel()
    let rail: RailViewController
    let chatList: ChatListViewController
    let sidebar: SidebarViewController
    let split = NSSplitViewController()
    private var presenceTask: Task<Void, Never>?
    private var didPlaceDivider = false

    public private(set) var selectedChatJid: String?
    private static let defaultContentSize = NSSize(width: 1100, height: 720)

    public init(client: WAClient) {
        self.client = client
        chatContainer = ChatContainerViewController(client: client)
        rail = RailViewController(model: railModel)
        chatList = ChatListViewController(client: client, filter: railModel.selection.filter())
        sidebar = SidebarViewController(rail: rail, chatList: chatList, session: client.session)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "BetterWA"
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 760, height: 480)
        window.identifier = NSUserInterfaceItemIdentifier("MainWindow")
        super.init(window: window)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = SidebarMetrics.minWidth
        sidebarItem.maximumThickness = RailMetrics.width + 480
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: chatContainer)
        contentItem.minimumThickness = 400
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "MainSplit"
        window.contentViewController = split
        // Assigning the content view controller shrinks the window to the split view's fitting size.
        window.setContentSize(Self.defaultContentSize)

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.delegate = self
        // Autosave restores here; reject a frame saved while the content was collapsed (teardown).
        let restored = window.setFrameAutosaveName("MainWindow")
        if !restored || window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            window.setContentSize(Self.defaultContentSize)
            window.center()
        }

        rail.onSelect = { [weak self] item in self?.selectRail(item) }
        chatList.onSelect = { [weak self] jid in self?.showChat(jid) }
        chatList.onTypeAhead = { [weak self] text in self?.chatContainer.beginComposing(with: text) }

        presenceTask = Task { [weak self, client] in
            for await presence in client.chatPresence {
                guard let self else { return }
                chatList.setTyping(chatJid: presence.chatJid, presence.state == .composing || presence.state == .recording)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if !didPlaceDivider {
            didPlaceDivider = true
            // Autosaved position wins; otherwise open at the ideal sidebar width.
            if split.splitView.subviews.first.map({ $0.frame.width < SidebarMetrics.minWidth }) ?? true {
                split.splitView.setPosition(SidebarMetrics.idealWidth, ofDividerAt: 0)
            }
        }
        window?.makeKeyAndOrderFront(sender)
        chatList.focus()
    }

    // MARK: Navigation

    func selectRail(_ item: RailItem) {
        railModel.selection = item
        chatList.filter = item.filter()
    }

    /// Selection changed in the list (click, arrows, or menu): swap content, update the title bar,
    /// and let WAKit mark the chat read.
    private func showChat(_ jid: String?) {
        selectedChatJid = jid
        chatContainer.show(chatJid: jid)
        updateTitle()
        guard let jid else {
            client.setFocus(chatJid: nil, windowIsKey: window?.isKeyWindow ?? false)
            return
        }
        if window?.isKeyWindow == true {
            Task { await client.openChat(jid) }
        } else {
            client.setFocus(chatJid: jid, windowIsKey: false)
        }
    }

    private func updateTitle() {
        guard let window else { return }
        guard let item = chatList.selectedItem ?? selectedChatJid.flatMap({ jid in chatList.items.first { $0.id == jid } }) else {
            window.title = "BetterWA"
            window.subtitle = ""
            return
        }
        window.title = item.title
        switch item.chat.kind {
        case .group:
            window.subtitle = item.chat.participantCount.map { "\($0) participants" } ?? "Group"
        case .dm:
            let phone = item.contact?.phone.map { "+" + $0 } ?? JID.phoneDisplay(item.chat.jid)
            window.subtitle = phone != item.title ? (phone ?? "") : ""
        default:
            window.subtitle = ""
        }
    }

    // MARK: Menu actions (responder chain targets)

    /// ⌘⌥1…9: `sender.tag` is the 1-based rail position.
    @objc public func selectRailItem(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, let item = railModel.item(at: tag) else { return }
        selectRail(item)
    }

    /// ⌘1…9: `sender.tag` is the 1-based pinned-chat position in the current list.
    @objc public func openPinnedChat(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, let jid = chatList.pinnedChatJid(at: tag - 1) else { return }
        chatList.select(jid)
    }

    @objc public func nextChat(_ sender: Any?) { chatList.selectAdjacent(offset: 1) }
    @objc public func previousChat(_ sender: Any?) { chatList.selectAdjacent(offset: -1) }
    @objc public func nextUnreadChat(_ sender: Any?) { chatList.selectUnread(forward: true) }
    @objc public func previousUnreadChat(_ sender: Any?) { chatList.selectUnread(forward: false) }

    @objc public func toggleUnread(_ sender: Any?) {
        guard let chat = chatList.selectedItem?.chat else { return }
        chatList.actions.toggleUnread(chat)
    }

    @objc public func toggleArchive(_ sender: Any?) {
        guard let chat = chatList.selectedItem?.chat else { return }
        chatList.actions.toggleArchive(chat)
    }

    @objc public func toggleMute(_ sender: Any?) {
        guard let chat = chatList.selectedItem?.chat else { return }
        chatList.actions.toggleMute(chat)
    }

    @objc public func togglePin(_ sender: Any?) {
        guard let chat = chatList.selectedItem?.chat else { return }
        chatList.actions.togglePin(chat)
    }

    @objc public func focusChatList(_ sender: Any?) { chatList.focus() }

    /// Shows or clears the typing indicator on a row (normally driven by `client.chatPresence`).
    public func setTyping(chatJid: String, _ typing: Bool) {
        chatList.setTyping(chatJid: chatJid, typing)
    }

    /// Selects the chat at `index` in the current list, as a click would.
    public func selectChat(at index: Int) {
        guard chatList.items.indices.contains(index) else { return }
        chatList.select(chatList.items[index].id)
    }

    /// The first `limit` chats in the current list, in display order.
    public func visibleChatJids(limit: Int) -> [String] {
        chatList.items.prefix(limit).map(\.id)
    }

    /// M6 lands the command bar here.
    @objc public func showCommandBar(_ sender: Any?) {
        WAKit.log.info("command bar requested (not implemented until M6)")
    }

    /// M6: opens the command bar scoped to contacts.
    @objc public func newChat(_ sender: Any?) {
        WAKit.log.info("new chat requested (not implemented until M6)")
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let chat = chatList.selectedItem?.chat
        switch menuItem.action {
        case #selector(toggleUnread(_:)):
            menuItem.title = (chat.map { $0.unreadCount > 0 || $0.markedUnread } ?? false) ? "Mark as Read" : "Mark as Unread"
            return chat != nil
        case #selector(toggleArchive(_:)):
            menuItem.title = chat?.archived == true ? "Unarchive" : "Archive"
            return chat != nil
        case #selector(toggleMute(_:)):
            menuItem.title = chat?.isMuted() == true ? "Unmute" : "Mute"
            return chat != nil
        case #selector(togglePin(_:)):
            menuItem.title = chat?.isPinned == true ? "Unpin" : "Pin"
            return chat != nil
        case #selector(openPinnedChat(_:)):
            return chatList.pinnedChatJid(at: menuItem.tag - 1) != nil
        case #selector(selectRailItem(_:)):
            return railModel.item(at: menuItem.tag) != nil
        case #selector(nextChat(_:)), #selector(previousChat(_:)):
            return !chatList.items.isEmpty
        case #selector(nextUnreadChat(_:)), #selector(previousUnreadChat(_:)):
            return chatList.items.contains(where: \.showsUnread)
        default:
            return true
        }
    }

    // MARK: NSWindowDelegate

    public func windowDidBecomeKey(_ notification: Notification) {
        chatList.windowKeyStateChanged()
        if let jid = selectedChatJid {
            Task { await client.openChat(jid) }
        } else {
            client.setFocus(chatJid: nil, windowIsKey: true)
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        chatList.windowKeyStateChanged()
        client.setFocus(chatJid: selectedChatJid, windowIsKey: false)
    }

    // MARK: NSToolbarDelegate

    private static let newChatItem = NSToolbarItem.Identifier("newChat")

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.newChatItem]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .space, Self.newChatItem]
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.newChatItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "New Chat"
            item.toolTip = "New Chat (⌘N)"
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Chat")
            item.isBordered = true
            item.action = #selector(newChat(_:))
            item.target = nil
            return item
        default:
            return nil
        }
    }
}
