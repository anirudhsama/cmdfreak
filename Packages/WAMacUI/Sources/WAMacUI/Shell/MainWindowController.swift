import AppKit
import SwiftUI
import WAKit

/// The main window: a three-column split view in the Mail layout. The sidebar item is the source
/// list of chat filters (standard sidebar behaviour, so macOS 26 draws it as floating glass), the
/// content-list item is the chat list, and the content item is the chat container. Every keyboard shortcut is a menu item whose action lands here via the responder chain.
@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    public let client: WAClient
    public let chatContainer: ChatContainerViewController

    let railModel = RailModel()
    let sourceList: SourceListViewController
    let chatList: ChatListViewController
    let chatListColumn: ChatListColumnViewController
    private var countsObservation: AnyDatabaseCancellable?
    let split = NSSplitViewController()
    private var presenceTask: Task<Void, Never>?
    private var didPlaceDivider = false
    /// Chat and action commands shown in the command bar; `register` more providers to extend it.
    public let commands = CommandRegistry.standard()
    let usage: QuickSearchUsageStore
    private var commandBarIfLoaded: CommandBarPanelController?
    var commandBar: CommandBarPanelController {
        if let commandBarIfLoaded { return commandBarIfLoaded }
        let bar = makeCommandBar()
        commandBarIfLoaded = bar
        return bar
    }

    public private(set) var selectedChatJid: String?
    private static let defaultContentSize = NSSize(width: 1280, height: 800)

    public init(client: WAClient) {
        self.client = client
        chatContainer = ChatContainerViewController(client: client)
        sourceList = SourceListViewController(model: railModel)
        chatList = ChatListViewController(client: client, filter: railModel.selection.filter())
        chatListColumn = ChatListColumnViewController(chatList: chatList, session: client.session)
        usage = QuickSearchUsageStore(url: URL(filePath: client.database.pool.path)
            .deletingLastPathComponent().appending(path: "quick-search-usage.json"))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "BetterWA"
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 760, height: 480)
        window.identifier = NSUserInterfaceItemIdentifier("MainWindow")
        super.init(window: window)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sourceList)
        sidebarItem.minimumThickness = SourceListMetrics.minWidth
        sidebarItem.maximumThickness = SourceListMetrics.maxWidth
        sidebarItem.canCollapse = true
        let listItem = NSSplitViewItem(contentListWithViewController: chatListColumn)
        listItem.minimumThickness = ChatListMetrics.minWidth
        listItem.maximumThickness = ChatListMetrics.maxWidth
        let contentItem = NSSplitViewItem(viewController: chatContainer)
        contentItem.minimumThickness = 400
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(listItem)
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

        sourceList.onSelect = { [weak self] item in self?.selectRail(item) }
        countsObservation = client.database.observeSidebarCounts { [railModel] counts in railModel.counts = counts }
        chatList.onSelect = { [weak self] jid in self?.showChat(jid) }
        chatList.onTypeAhead = { [weak self] text in self?.chatContainer.beginComposing(with: text) }
        chatContainer.onEscapeToChatList = { [weak self] in self?.chatList.focus() }

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
            // Autosaved positions win; otherwise open at the ideal column widths.
            let views = split.splitView.subviews
            if views.count == 3, views[0].frame.width < SourceListMetrics.minWidth || views[1].frame.width < ChatListMetrics.minWidth {
                split.splitView.setPosition(SourceListMetrics.idealWidth, ofDividerAt: 0)
                split.splitView.setPosition(SourceListMetrics.idealWidth + ChatListMetrics.idealWidth, ofDividerAt: 1)
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
        usage.recordVisit(of: jid)
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

    // MARK: Command bar

    /// ⌘K: toggles the command bar over chats, contacts and actions.
    @objc public func showCommandBar(_ sender: Any?) {
        if commandBar.isVisible, commandBar.model.scope == .all {
            commandBar.hide()
        } else {
            commandBar.show(scope: .all, context: commandContext)
        }
    }

    /// ⌘N: the command bar scoped to contacts; picking one without a chat starts a DM.
    @objc public func newChat(_ sender: Any?) {
        commandBar.show(scope: .contacts, context: commandContext)
    }

    public var isCommandBarVisible: Bool { commandBarIfLoaded?.isVisible ?? false }

    private var commandContext: CommandContext {
        CommandContext(chat: selectedChatItem)
    }

    private var selectedChatItem: ChatListItem? {
        chatList.selectedItem ?? selectedChatJid.flatMap { jid in chatList.items.first { $0.id == jid } }
    }

    private func makeCommandBar() -> CommandBarPanelController {
        let model = CommandBarModel(database: client.database, usage: usage, registry: commands)
        model.onOpenChat = { [weak self] candidate in self?.open(candidate) }
        model.onPerform = { [weak self] action in
            // After the panel has closed, so the main window is key again (Log Out shows an alert).
            DispatchQueue.main.async { action.perform(self?.window) }
        }
        return CommandBarPanelController(model: model, owner: window!)
    }

    /// Opens a command-bar pick: switches the rail if the chat is outside the current filter,
    /// creates the chat first for a contact without one, then selects it like a click would.
    func open(_ candidate: QuickSearchCandidate) {
        guard candidate.hasChat else {
            Task { [weak self, client] in
                do {
                    let jid = try await client.startChat(with: candidate.jid)
                    await self?.reveal(jid, archived: false, waitForList: true)
                } catch {
                    WAKit.log.error("start chat failed: \(error)")
                }
            }
            return
        }
        Task { await reveal(candidate.jid, archived: candidate.archived, waitForList: false) }
    }

    private func reveal(_ jid: String, archived: Bool, waitForList: Bool) async {
        // Unread/Groups/tag filters may not contain the chat; fall back to the list that does.
        let home: RailItem = archived ? .archived : .chats
        if railModel.selection != home, !chatList.items.contains(where: { $0.id == jid }) {
            selectRail(home)
        }
        // A just-created chat reaches the list through its observation a moment after the write.
        if waitForList {
            for _ in 0..<60 where !chatList.items.contains(where: { $0.id == jid }) {
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        chatList.select(jid)
        if !chatContainer.focusCompose() { chatList.focus() }
    }

    // MARK: Chat-view seams (Esc, ⇧⌘O, Space)

    private var windowIsKeyForMenus: Bool {
        #if DEBUG
        if Self.debugAssumeKeyWindow { return true }
        #endif
        return window?.isKeyWindow == true
    }

    #if DEBUG
    /// Self-test only: the test session may have no key window (locked screen).
    public static var debugAssumeKeyWindow = false
    #endif

    private var isComposingMarkedText: Bool {
        (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
    }

    /// Esc: the chat view clears reply/edit state first; otherwise focus moves to the chat list.
    @objc public func cancelOrFocusChatList(_ sender: Any?) {
        if chatContainer.cancelTransientState() { return }
        chatList.focus()
    }

    /// ⇧⌘O: forwarded to the chat view's attach flow.
    @objc public func attachFile(_ sender: Any?) {
        chatContainer.attachFile()
    }

    /// Space with the message list focused: Quick Look on the selected media.
    @objc public func quickLookSelection(_ sender: Any?) {
        chatContainer.quickLook()
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let chat = chatList.selectedItem?.chat
        switch menuItem.action {
        case #selector(cancelOrFocusChatList(_:)):
            menuItem.title = chatContainer.transientStateTitle ?? "Focus Chat List"
            // Disabled items do not claim the key, so Esc still reaches other windows and input methods.
            return windowIsKeyForMenus && !isComposingMarkedText
        case #selector(attachFile(_:)):
            return windowIsKeyForMenus && chatContainer.canAttach
        case #selector(quickLookSelection(_:)):
            return windowIsKeyForMenus && chatContainer.canQuickLook
        case #selector(showCommandBar(_:)):
            menuItem.title = isCommandBarVisible ? "Hide Command Bar" : "Command Bar"
            return true
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
