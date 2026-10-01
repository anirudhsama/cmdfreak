import AppKit
import WAKit

/// The chat list: an `NSTableView` driven by a diffable snapshot of chat JIDs. Row content lives
/// in long-lived `ChatRowState` objects keyed by JID; a snapshot change only re-points reused cells
/// at existing states. The list is fed by WAKit's chat-list observation (first value synchronous),
/// so the first frame has content. Swiping a row uncovers its actions (`RowSwipeController`):
/// read/unread on the leading edge, archive and pin on the trailing edge.
@MainActor
final class ChatListViewController: NSViewController, NSTableViewDelegate {
    let client: WAClient
    let actions: ChatActions
    let appearance = ChatListAppearance()

    /// Fires on click-, menu- or search-driven selection changes. `nil` when the selection clears.
    var onSelect: ((String?) -> Void)?

    var filter: ChatFilter {
        didSet { if filter != oldValue { startObserving() } }
    }

    /// The rows on screen: the observed chats narrowed by `searchText`.
    private(set) var items: [ChatListItem] = []
    private var observedItems: [ChatListItem] = []

    /// Filters the list by chat name or phone number; empty shows everything.
    var searchText = "" {
        didSet { if searchText != oldValue { apply(observedItems) } }
    }

    /// Space above the first row: the toolbar plus whatever floats over the list (the search field).
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue else { return }
            let atTop = scrollView.contentView.bounds.minY <= -oldValue + 1
            scrollView.contentInsets.top = topInset
            if atTop {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: -topInset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }
    private(set) var selectedJid: String?

    private let tableView = ChatListTableView()
    private lazy var swipe = RowSwipeController(tableView: tableView)
    private let scrollView = NSScrollView()
    private var dataSource: NSTableViewDiffableDataSource<Int, String>!
    private var states: [String: ChatRowState] = [:]
    private let avatarLoader: AvatarLoader
    private var observation: AnyDatabaseCancellable?
    private var hasAppliedSnapshot = false
    /// Chat → sender → who is typing or recording there.
    private var typists: [String: [String: Typist]] = [:]
    /// Every typing change, for the open chat's header and message list: the chat may be open while
    /// the current filter has no row for it.
    var onTypingChange: ((_ chatJid: String, ChatTyping?) -> Void)?

    init(client: WAClient, filter: ChatFilter) {
        self.client = client
        self.filter = filter
        actions = ChatActions(client: client)
        avatarLoader = AvatarLoader(avatars: client.avatars, pixelSize: Int(ChatRowMetrics.avatarSize) * 2)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: View

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chat"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.intercellSpacing = .zero
        tableView.rowHeight = ChatRowMetrics.height
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.delegate = self
        tableView.swipe = swipe
        swipe.actions = { [weak self] row, edge in
            guard let self, let jid = dataSource.itemIdentifier(forRow: row), let chat = states[jid]?.item.chat else { return [] }
            return actions.swipeActions(for: chat, edge: edge)
        }

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        // Set by the column from its safe area plus the floating search field (`topInset`).
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets.bottom = 12
        view = scrollView

        dataSource = NSTableViewDiffableDataSource<Int, String>(tableView: tableView) { [weak self] tableView, _, _, jid in
            let cell = tableView.makeView(withIdentifier: ChatRowCell.identifier, owner: nil) as? ChatRowCell ?? {
                let cell = ChatRowCell()
                cell.identifier = ChatRowCell.identifier
                return cell
            }()
            guard let self, let state = states[jid] else { return cell }
            cell.configure(state: state, appearance: appearance)
            cell.onContextMenu = { [weak self] state in self?.actions.contextMenu(for: state.item.chat) }
            avatarLoader.load(state)
            return cell
        }
        dataSource.rowViewProvider = { [weak self] tableView, _, jid in
            let rowView = tableView.makeView(withIdentifier: ChatTableRowView.identifier, owner: nil) as? ChatTableRowView ?? {
                let rowView = ChatTableRowView()
                rowView.identifier = ChatTableRowView.identifier
                return rowView
            }()
            rowView.state = (jid as? String).flatMap { self?.states[$0] }
            return rowView
        }
        dataSource.defaultRowAnimation = .effectFade
        startObserving()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateEmphasis()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        swipe.reset()
    }

    // MARK: Data

    private func startObserving() {
        observation?.cancel()
        observation = client.database.observeChatList(filter: filter) { [weak self] items in
            self?.apply(items)
        }
    }

    private func apply(_ newItems: [ChatListItem]) {
        observedItems = newItems
        var live: [String: ChatRowState] = [:]
        live.reserveCapacity(newItems.count)
        for item in newItems {
            if let state = states[item.id] {
                let avatarURL = state.avatarURL
                state.apply(item)
                // A picture fetched, changed or removed since the row was configured.
                if state.avatarURL != avatarURL { avatarLoader.reload(state) }
                live[item.id] = state
            } else {
                let state = ChatRowState(item: item)
                state.typing = typing(in: item.id)
                live[item.id] = state
            }
        }
        states = live
        items = Self.matching(newItems, searchText)

        let selectedWasVisible = isSelectedRowVisible
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(items.map(\.id))
        let animate = hasAppliedSnapshot && view.window != nil
        dataSource.apply(snapshot, animatingDifferences: animate)
        hasAppliedSnapshot = true
        swipe.reconcile()

        if let selectedJid, row(for: selectedJid) == nil {
            // Selected chat left this filter (archived, or the rail switched); keep the content side as is.
            tableView.deselectAll(nil)
        } else {
            syncSelectionToTableView()
            // The open chat jumped (usually to the top, after a send): follow it if it was on screen.
            if selectedWasVisible {
                tableView.layoutSubtreeIfNeeded()
                if !isSelectedRowVisible { revealSelectedRow() }
            }
        }
    }

    private static func matching(_ items: [ChatListItem], _ query: String) -> [ChatListItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        let digits = query.filter(\.isNumber)
        let isPhoneQuery = !digits.isEmpty && query.allSatisfy { $0.isNumber || " +-()".contains($0) }
        return items.filter { item in
            item.title.localizedStandardContains(query)
                || (isPhoneQuery && (item.contact?.phone ?? item.chat.jid).contains(digits))
        }
    }

    private var isSelectedRowVisible: Bool {
        guard let selectedJid, let row = row(for: selectedJid) else { return false }
        let frame = tableView.rect(ofRow: row)
        // Rows under the toolbar (the top content inset) count as hidden.
        var visible = tableView.visibleRect
        let inset = scrollView.contentInsets.top
        visible.origin.y += inset
        visible.size.height -= inset
        return visible.intersects(frame)
    }

    /// Scrolls the least needed to show the selected row in full below the toolbar and search
    /// field (`scrollRowToVisible` ignores the top inset and can leave it under them).
    private func revealSelectedRow() {
        guard let selectedJid, let row = row(for: selectedJid) else { return }
        let frame = tableView.rect(ofRow: row)
        let clip = scrollView.contentView
        let inset = scrollView.contentInsets.top
        let top = clip.bounds.minY + inset
        var y: CGFloat
        if frame.minY < top {
            // The first row goes all the way up, to the top of the content.
            y = row == 0 ? -inset : frame.minY - inset
        } else if frame.maxY > clip.bounds.maxY {
            y = frame.maxY - clip.bounds.height
        } else {
            return
        }
        y = max(-inset, y)
        guard abs(y - clip.bounds.minY) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Selection

    func row(for jid: String) -> Int? {
        dataSource.row(forItemIdentifier: jid)
    }

    /// Selects `jid` (or clears with `nil`), scrolls to it, and reports it through `onSelect`.
    func select(_ jid: String?) {
        selectedJid = jid
        syncSelectionToTableView(scroll: true)
        onSelect?(jid)
    }

    /// Re-applies `selectedJid` to the table view without notifying.
    private func syncSelectionToTableView(scroll: Bool = false) {
        guard let selectedJid, let row = row(for: selectedJid) else {
            if tableView.selectedRow >= 0 { tableView.deselectAll(nil) }
            return
        }
        if tableView.selectedRowIndexes != [row] { tableView.selectRowIndexes([row], byExtendingSelection: false) }
        if scroll {
            tableView.layoutSubtreeIfNeeded()
            revealSelectedRow()
        }
    }

    func selectAdjacent(offset: Int) {
        guard !items.isEmpty else { return }
        let current = selectedJid.flatMap { jid in items.firstIndex { $0.id == jid } }
        let next: Int
        if let current {
            next = min(max(current + offset, 0), items.count - 1)
        } else {
            next = offset > 0 ? 0 : items.count - 1
        }
        select(items[next].id)
    }

    func selectUnread(forward: Bool) {
        guard !items.isEmpty else { return }
        let start = selectedJid.flatMap { jid in items.firstIndex { $0.id == jid } } ?? (forward ? -1 : items.count)
        let count = items.count
        for step in 1...count {
            let index = ((start + (forward ? step : -step)) % count + count) % count
            if items[index].showsUnread {
                select(items[index].id)
                return
            }
        }
    }

    func pinnedChatJid(at position: Int) -> String? {
        let pinned = items.lazy.filter { $0.chat.isPinned }
        return pinned.dropFirst(position).first?.id
    }

    func rowState(for jid: String) -> ChatRowState? { states[jid] }

    var selectedItem: ChatListItem? {
        selectedJid.flatMap { jid in states[jid]?.item }
    }

    private func updateEmphasis() {
        appearance.isEmphasized = tableView.window?.isKeyWindow == true
    }

    func windowKeyStateChanged() { updateEmphasis() }

    // MARK: Typing

    func setChatState(chatJid: String, senderJid: String, senderName: String?, _ chatState: ChatState) {
        typists[chatJid]?[senderJid]?.expiry.cancel()
        if chatState == .paused {
            typists[chatJid]?[senderJid] = nil
            if typists[chatJid]?.isEmpty == true { typists[chatJid] = nil }
        } else {
            // WhatsApp does not always send `paused`; expire on our own.
            let expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.setChatState(chatJid: chatJid, senderJid: senderJid, senderName: nil, .paused)
            }
            let name = senderName ?? JID.phoneDisplay(senderJid) ?? "Someone"
            typists[chatJid, default: [:]][senderJid] = Typist(name: name, recording: chatState == .recording, expiry: expiry)
        }
        let typing = typing(in: chatJid)
        states[chatJid]?.typing = typing
        onTypingChange?(chatJid, typing)
    }

    func typing(in chatJid: String) -> ChatTyping? {
        guard let typists = typists[chatJid], !typists.isEmpty else { return nil }
        // A sender equal to the chat (a DM, or the debug hook) needs no name.
        let senders = ChatKind(jid: chatJid) == .group
            ? typists.filter { $0.key != chatJid }.map { ChatTyping.Sender(jid: $0.key, name: $0.value.name) }.sorted { $0.name < $1.name }
            : []
        return ChatTyping(senders: senders, recording: typists.values.allSatisfy(\.recording))
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        // A click while a row is swiped open only closes it.
        if swipe.isOpen {
            swipe.close()
            return tableView.selectedRowIndexes
        }
        // A chat stays open once chosen: refuse user-driven clearing (⌘-click, a click below the rows).
        return proposed.isEmpty && selectedJid != nil ? tableView.selectedRowIndexes : proposed
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0, let jid = dataSource.itemIdentifier(forRow: tableView.selectedRow) else { return }
        guard jid != selectedJid else { return }
        selectedJid = jid
        onSelect?(jid)
    }
}

/// Never takes keyboard focus: focus lives in the open chat, and chats switch by click, menu
/// shortcut or the search field.
final class ChatListTableView: NSTableView {
    var swipe: RowSwipeController?

    override var acceptsFirstResponder: Bool { false }
    // `makeFirstResponder` does not consult `acceptsFirstResponder`; clicks go through it.
    override func becomeFirstResponder() -> Bool { false }

    override func scrollWheel(with event: NSEvent) {
        guard let swipe else { return super.scrollWheel(with: event) }
        swipe.scrollWheel(event) { super.scrollWheel(with: $0) }
    }
}

#if DEBUG
extension ChatListViewController {
    var debugRefusesFocus: Bool {
        guard let window = view.window else { return false }
        let previous = window.firstResponder
        defer { window.makeFirstResponder(previous) }
        window.makeFirstResponder(tableView)
        return window.firstResponder !== tableView
    }

    /// A synthetic click (mouse-down and -up) on the row at `index`, at the first point from its
    /// trailing end that hits the table. Delivered through the window: the table handles clicks with
    /// gesture recognizers, which never see a direct `mouseDown`.
    func debugClick(row index: Int, modifiers: NSEvent.ModifierFlags = []) {
        guard let window, let frameView = window.contentView?.superview, items.indices.contains(index) else { return }
        let frame = tableView.rect(ofRow: index)
        let candidates = stride(from: frame.maxX - 20, to: frame.minX, by: -20).map {
            tableView.convert(NSPoint(x: $0, y: frame.midY), to: nil)
        }
        guard let point = candidates.first(where: { frameView.hitTest($0)?.isDescendant(of: tableView) == true }) else { return }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        window.sendEvent(down)
        window.sendEvent(up)
    }

    private var window: NSWindow? { view.window }
}
#endif

private struct Typist {
    var name: String
    var recording: Bool
    var expiry: Task<Void, Never>
}
