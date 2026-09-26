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

    /// Fires on user- or keyboard-driven selection changes. `nil` when the selection clears.
    var onSelect: ((String?) -> Void)?
    /// Printable text typed while the list has keyboard focus.
    var onTypeAhead: ((String) -> Void)?

    var filter: ChatFilter {
        didSet { if filter != oldValue { startObserving() } }
    }

    private(set) var items: [ChatListItem] = []
    private(set) var selectedJid: String?

    private let collectionView = ChatListCollectionView()
    private let scrollView = NSScrollView()
    private var dataSource: NSCollectionViewDiffableDataSource<Int, String>!
    private var states: [String: ChatRowState] = [:]
    private let avatarLoader: AvatarLoader
    private var observation: AnyDatabaseCancellable?
    private var hasAppliedSnapshot = false
    private var typingTimers: [String: Task<Void, Never>] = [:]

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
        collectionView.onTypeAhead = { [weak self] text in self?.onTypeAhead?(text) }
        collectionView.onFocusChange = { [weak self] in self?.updateEmphasis() }

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = true
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
        section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0)
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
        var live: [String: ChatRowState] = [:]
        live.reserveCapacity(newItems.count)
        for item in newItems {
            if let state = states[item.id] {
                state.apply(item)
                live[item.id] = state
            } else {
                live[item.id] = ChatRowState(item: item)
            }
        }
        states = live
        items = newItems

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(newItems.map(\.id))
        let animate = hasAppliedSnapshot && view.window != nil
        dataSource.apply(snapshot, animatingDifferences: animate)
        hasAppliedSnapshot = true

        if let selectedJid, states[selectedJid] == nil {
            // Selected chat left this filter (archived, or the rail switched); keep the content side as is.
            collectionView.deselectAll(nil)
        } else {
            syncSelectionToCollectionView()
        }
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
        if scroll { collectionView.scrollToItems(at: target, scrollPosition: .nearestHorizontalEdge) }
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

    func focus() {
        view.window?.makeFirstResponder(collectionView)
    }

    private func updateEmphasis() {
        let window = collectionView.window
        appearance.isEmphasized = window?.isKeyWindow == true && window?.firstResponder === collectionView
    }

    func windowKeyStateChanged() { updateEmphasis() }

    // MARK: Typing

    func setTyping(chatJid: String, _ typing: Bool) {
        typingTimers[chatJid]?.cancel()
        typingTimers[chatJid] = nil
        states[chatJid]?.isTyping = typing
        guard typing else { return }
        // WhatsApp does not always send `paused`; expire on our own.
        typingTimers[chatJid] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.states[chatJid]?.isTyping = false
            self?.typingTimers[chatJid] = nil
        }
    }

    // MARK: NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let path = indexPaths.first, let jid = dataSource.itemIdentifier(for: path) else { return }
        guard jid != selectedJid else { return }
        selectedJid = jid
        onSelect?(jid)
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        // Only user-driven clearing (e.g. ⌘-click) reaches here with nothing left selected.
        guard collectionView.selectionIndexPaths.isEmpty, selectedJid != nil else { return }
        guard let path = indexPaths.first, dataSource.itemIdentifier(for: path) == selectedJid else { return }
        if states[selectedJid!] != nil {
            selectedJid = nil
            onSelect?(nil)
        }
    }
}

/// Collection view that forwards printable typing to the compose seam and reports focus changes.
final class ChatListCollectionView: NSCollectionView {
    var onTypeAhead: ((String) -> Void)?
    var onFocusChange: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if let text = Self.typedText(event) {
            onTypeAhead?(text)
            return
        }
        super.keyDown(with: event)
    }

    private static func typedText(_ event: NSEvent) -> String? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .function]),
              let text = event.characters, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
        else { return nil }
        return text
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        onFocusChange?()
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        onFocusChange?()
        return ok
    }
}
