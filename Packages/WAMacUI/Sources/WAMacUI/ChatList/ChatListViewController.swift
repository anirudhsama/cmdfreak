import AppKit
import WAKit

/// The chat list: an `NSCollectionView` driven by a diffable snapshot of chat JIDs. Row content
/// lives in long-lived `ChatRowState` objects keyed by JID; a snapshot change only re-points
/// reused items at existing states. The list is fed by WAKit's chat-list observation (first value
/// synchronous), so the first frame has content.
@MainActor
final class ChatListViewController: NSViewController, NSCollectionViewDelegate {
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

    private let collectionView = ChatListCollectionView()
    private let scrollView = NSScrollView()
    private var dataSource: NSCollectionViewDiffableDataSource<Int, String>!
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
        avatarLoader = AvatarLoader(avatars: client.avatars)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: View

    override func loadView() {
        collectionView.collectionViewLayout = Self.makeLayout()
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsEmptySelection = true
        collectionView.allowsMultipleSelection = false
        collectionView.delegate = self
        collectionView.register(ChatRowItem.self, forItemWithIdentifier: ChatRowItem.identifier)

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        // Set by the column from its safe area plus the floating search field (`topInset`).
        scrollView.automaticallyAdjustsContentInsets = false
        view = scrollView

        dataSource = NSCollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] collectionView, indexPath, jid in
            let item = collectionView.makeItem(withIdentifier: ChatRowItem.identifier, for: indexPath)
            guard let self, let row = item as? ChatRowItem, let state = states[jid] else { return item }
            row.configure(state: state, appearance: appearance)
            row.onContextMenu = { [weak self] state in self?.actions.contextMenu(for: state.item.chat) }
            avatarLoader.load(state)
            return item
        }
        startObserving()
    }

    private static func makeLayout() -> NSCollectionViewCompositionalLayout {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(ChatRowMetrics.height))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0)
        return NSCollectionViewCompositionalLayout(section: section)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateEmphasis()
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
                state.apply(item)
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

        if let selectedJid, indexPath(for: selectedJid) == nil {
            // Selected chat left this filter (archived, or the rail switched); keep the content side as is.
            collectionView.deselectAll(nil)
        } else {
            syncSelectionToCollectionView()
            // The open chat jumped (usually to the top, after a send): follow it if it was on screen.
            if selectedWasVisible {
                collectionView.layoutSubtreeIfNeeded()
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
        guard let selectedJid, let path = indexPath(for: selectedJid),
              let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { return false }
        // Rows under the toolbar (the top content inset) count as hidden.
        var visible = collectionView.visibleRect
        let inset = scrollView.contentInsets.top
        visible.origin.y += inset
        visible.size.height -= inset
        return visible.intersects(frame)
    }

    /// Scrolls the least needed to show the selected row in full below the toolbar and search
    /// field (`scrollToItems` ignores the top inset and can leave it under them).
    private func revealSelectedRow() {
        guard let selectedJid, let path = indexPath(for: selectedJid),
              let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { return }
        let clip = scrollView.contentView
        let inset = scrollView.contentInsets.top
        let top = clip.bounds.minY + inset
        var y: CGFloat
        if frame.minY < top {
            // The first row goes all the way up, so the section's top inset shows too.
            y = path.item == 0 ? -inset : frame.minY - inset
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

    func indexPath(for jid: String) -> IndexPath? {
        dataSource.indexPath(for: jid)
    }

    /// Selects `jid` (or clears with `nil`), scrolls to it, and reports it through `onSelect`.
    func select(_ jid: String?) {
        selectedJid = jid
        syncSelectionToCollectionView(scroll: true)
        onSelect?(jid)
    }

    /// Re-applies `selectedJid` to the collection view without notifying.
    private func syncSelectionToCollectionView(scroll: Bool = false) {
        guard let selectedJid, let path = indexPath(for: selectedJid) else {
            if !collectionView.selectionIndexPaths.isEmpty { collectionView.deselectAll(nil) }
            return
        }
        let target: Set<IndexPath> = [path]
        if collectionView.selectionIndexPaths != target { collectionView.selectionIndexPaths = target }
        if scroll {
            collectionView.layoutSubtreeIfNeeded()
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
        appearance.isEmphasized = collectionView.window?.isKeyWindow == true
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

    // MARK: NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let path = indexPaths.first, let jid = dataSource.itemIdentifier(for: path) else { return }
        guard jid != selectedJid else { return }
        selectedJid = jid
        syncSelectionToCollectionView()
        onSelect?(jid)
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        // A chat stays open once chosen: undo user-driven clearing (⌘-click, a click below the rows).
        guard collectionView.selectionIndexPaths.isEmpty, selectedJid != nil else { return }
        syncSelectionToCollectionView()
    }
}

/// Never takes keyboard focus: focus lives in the open chat, and chats switch by click, menu
/// shortcut or the search field.
final class ChatListCollectionView: NSCollectionView {
    override var acceptsFirstResponder: Bool { false }
    // `makeFirstResponder` does not consult `acceptsFirstResponder`; clicks go through it.
    override func becomeFirstResponder() -> Bool { false }
}

#if DEBUG
extension ChatListViewController {
    var debugRefusesFocus: Bool {
        guard let window = view.window else { return false }
        let previous = window.firstResponder
        defer { window.makeFirstResponder(previous) }
        window.makeFirstResponder(collectionView)
        return window.firstResponder !== collectionView
    }

    /// A synthetic click (mouse-down and -up) on the visible part of the row at `index`; the
    /// floating sidebar covers the list's leading edge. Delivered to the collection view directly:
    /// a window that is not key (a locked test session) swallows the first click.
    func debugClick(row index: Int, modifiers: NSEvent.ModifierFlags = []) {
        guard let window, let frameView = window.contentView?.superview, items.indices.contains(index),
              let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
        let candidates = stride(from: frame.maxX - 20, to: frame.minX, by: -20).map {
            collectionView.convert(NSPoint(x: $0, y: frame.midY), to: nil)
        }
        guard let point = candidates.first(where: { frameView.hitTest($0)?.isDescendant(of: collectionView) == true }) else { return }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        collectionView.mouseDown(with: down)
        collectionView.mouseUp(with: up)
    }

    private var window: NSWindow? { view.window }
}
#endif

private struct Typist {
    var name: String
    var recording: Bool
    var expiry: Task<Void, Never>
}
