import AppKit
import Quartz
import UniformTypeIdentifiers
import WAKit
import os

/// Actions the list needs the owner (ChatViewController) to perform.
@MainActor
protocol MessageListActions: AnyObject {
    func reply(to item: MessageItem)
    func toggleReaction(_ emoji: String, on item: MessageItem)
    func edit(_ item: MessageItem)
    func revoke(_ item: MessageItem)
    func retry(_ item: MessageItem)
    func typeToCompose(_ text: String)
    func escapeFromList()
}

/// The message table. Row heights come from `LayoutPlan`s; nothing is measured in delegate callbacks
/// except a cache-miss plan computation for a row scrolled in during live resize.
@MainActor
final class MessageListController: NSViewController {
    typealias M = MessageTextConfiguration.Metrics

    let client: WAClient
    weak var actions: (any MessageListActions)?

    let scrollView = NSScrollView()
    let tableView = ChatTableView()

    private(set) var rows: ChatRows
    private var plans: [String: LayoutPlan] = [:]
    private var width: CGFloat = 0
    private var ownJid: String?
    private var peerName: String?
    var chatName: String? { peerName }
    private var loader: ChatWindowLoader?
    private var feedTask: Task<Void, Never>?
    private var loadingOlder = false
    private var loadingNewer = false
    private var warmupTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var bottomInset: CGFloat = 0
    private var needsInitialScroll = false
    private var bottomGapBeforeLayout: CGFloat = 0
    private var wasAtBottom = true
    private var pendingFlashId: String?
    private var highlightedRow: Int?
    private var previewItems: [PreviewItem] = []
    private var previewIndex = 0

    static let bottomTolerance: CGFloat = 8

    init(client: WAClient) {
        self.client = client
        self.rows = ChatRows(chatJid: "", isGroupChat: false)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        feedTask?.cancel()
        warmupTask?.cancel()
        progressTask?.cancel()
    }

    // MARK: - View

    override func loadView() {
        let column = NSTableColumn(identifier: .init("message"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.gridStyleMask = []
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.scrollerStyle = .overlay
        view = scrollView

        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveResizeEnded), name: NSWindow.didEndLiveResizeNotification, object: nil)
        startProgressObservation()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let top = view.safeAreaInsets.top + M.listTopInset
        if scrollView.contentInsets.top != top || scrollView.contentInsets.bottom != bottomInset {
            scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: bottomInset, right: 0)
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }
        let newWidth = floor(scrollView.contentView.bounds.width)
        if newWidth > 0, abs(newWidth - width) >= 1 {
            widthDidChange(to: newWidth)
        }
        if needsInitialScroll, tableView.numberOfRows > 0 {
            needsInitialScroll = false
            scrollToBottom()
            scheduleWarmup()
        } else if wasAtBottom, !needsInitialScroll {
            // Live resize and inset changes keep the newest message pinned.
            scrollToBottom()
        }
    }

    /// The compose bar height plus spacing; the list scrolls under the glass.
    func setBottomInset(_ inset: CGFloat) {
        guard inset != bottomInset else { return }
        let atBottom = isAtBottom
        bottomInset = inset
        scrollView.contentInsets.bottom = inset
        scrollView.scrollerInsets.bottom = inset
        if atBottom { scrollToBottom() }
    }

    var measurementWidth: CGFloat {
        let w = floor(scrollView.contentView.bounds.width)
        return w > 0 ? w : max(320, floor(view.bounds.width))
    }

    // MARK: - Chat lifecycle

    func clear() {
        feedTask?.cancel()
        feedTask = nil
        warmupTask?.cancel()
        rows = ChatRows(chatJid: "", isGroupChat: false)
        plans = [:]
        loader = nil
        previewItems = []
        tableView.reloadData()
    }

    /// Installs a prepared window and renders it in the current runloop turn.
    func show(_ prepared: PreparedChat, changes: AsyncStream<MessageChange>) {
        let state = Signposts.poi.beginInterval("OpenChatRender", id: Signposts.poi.makeSignpostID())
        defer { Signposts.poi.endInterval("OpenChatRender", state) }
        feedTask?.cancel()
        warmupTask?.cancel()
        rows = prepared.rows
        ownJid = prepared.ownJid
        peerName = prepared.chat?.name
        loader = client.windowLoader(for: prepared.chatJid)
        width = measurementWidth
        plans = abs(prepared.width - width) < 0.5 ? prepared.plans : [:]
        wasAtBottom = true
        needsInitialScroll = true
        highlightedRow = nil
        tableView.reloadData()
        view.layoutSubtreeIfNeeded()
        scrollToBottom()
        needsInitialScroll = false
        scheduleWarmup()

        feedTask = Task { [weak self] in
            for await change in changes {
                guard let self, !Task.isCancelled else { return }
                self.apply(change)
            }
        }
    }

    // MARK: - Plans

    private func plan(for id: String) -> LayoutPlan {
        if let p = plans[id], abs(p.width - width) < 0.5 { return p }
        guard let i = rows.messageIndex[id] else {
            // Should not happen; a zero-height plan keeps the table consistent.
            return plans[id] ?? LayoutPlanner.plan(rows.messages[0], rows.context(forMessageAt: 0, width: width, ownJid: ownJid, peerName: peerName))
        }
        let ctx = rows.context(forMessageAt: i, width: width, ownJid: ownJid, peerName: peerName)
        let p = LayoutPlanCache.shared.plan(for: rows.messages[i], context: ctx)
        plans[id] = p
        return p
    }

    private func invalidatePlans(for ids: some Sequence<String>) {
        for id in ids { plans[id] = nil }
    }

    /// Computes plans for `items` at `width` off the main thread.
    private nonisolated static func computePlans(_ rows: ChatRows, width: CGFloat, ownJid: String?, peerName: String?) -> [String: LayoutPlan] {
        var out: [String: LayoutPlan] = [:]
        out.reserveCapacity(rows.messages.count)
        for i in rows.messages.indices {
            let ctx = rows.context(forMessageAt: i, width: width, ownJid: ownJid, peerName: peerName)
            out[rows.messages[i].id] = LayoutPlanCache.shared.plan(for: rows.messages[i], context: ctx)
        }
        return out
    }

    // MARK: - Width changes

    private func widthDidChange(to newWidth: CGFloat) {
        width = newWidth
        guard tableView.numberOfRows > 0 else { return }
        if view.inLiveResize {
            // Only the rows on screen are re-measured now; the rest catch up when the resize ends.
            let visible = tableView.rows(in: tableView.visibleRect)
            let range = max(0, visible.location - 4)..<min(tableView.numberOfRows, visible.location + visible.length + 4)
            withoutAnimation {
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: range))
                reconfigureVisibleCells()
            }
        } else {
            recomputeAllPlans()
        }
    }

    /// Cells keep the plan they were configured with; after a width change they need the new one.
    private func reconfigureVisibleCells() {
        tableView.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: 0) as? MessageCell, case .message(let id) = rows.row(at: row),
                  let item = rows.item(id: id) else { return }
            cell.configure(item: item, plan: plan(for: id))
            cell.layoutSubtreeIfNeeded()
        }
    }

    @objc private func liveResizeEnded(_ note: Notification) {
        guard (note.object as? NSWindow) === view.window else { return }
        recomputeAllPlans()
    }

    private func recomputeAllPlans() {
        let snapshot = rows
        let w = width
        let own = ownJid
        let peer = peerName
        Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) {
                Self.computePlans(snapshot, width: w, ownJid: own, peerName: peer)
            }.value
            guard let self, self.width == w, self.rows.chatJid == snapshot.chatJid else { return }
            for (id, p) in computed where self.rows.messageIndex[id] != nil { self.plans[id] = p }
            let atBottom = self.isAtBottom
            self.maintainingBottomDistance(unless: atBottom) {
                self.withoutAnimation {
                    self.tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.tableView.numberOfRows))
                    self.reconfigureVisibleCells()
                }
            }
            if atBottom { self.scrollToBottom() }
        }
    }

    // MARK: - Applying changes

    private func apply(_ change: MessageChange) {
        let state = Signposts.poi.beginInterval("ApplyChange", id: Signposts.poi.makeSignpostID())
        defer { Signposts.poi.endInterval("ApplyChange", state) }
        let atBottom = isAtBottom
        let update = rows.apply(change)
        invalidatePlans(for: change.ids)
        if case .replace(let old, _) = change { plans[old] = nil }
        applyUpdate(update, scrollToBottomIfWasAtBottom: atBottom)
    }

    private func applyUpdate(_ update: ChatRows.Update, scrollToBottomIfWasAtBottom atBottom: Bool) {
        guard !update.isEmpty else { return }
        // Neighbour rows whose grouping changed need fresh plans.
        for i in update.reloaded { if case .message(let id) = rows.row(at: i) { plans[id] = nil } }
        maintainingBottomDistance(unless: atBottom) {
            withoutAnimation {
                if update.reloadAll {
                    plans = [:]
                    tableView.reloadData()
                } else {
                    tableView.beginUpdates()
                    if !update.removed.isEmpty { tableView.removeRows(at: update.removed, withAnimation: []) }
                    if !update.inserted.isEmpty { tableView.insertRows(at: update.inserted, withAnimation: []) }
                    tableView.endUpdates()
                    if !update.reloaded.isEmpty {
                        tableView.noteHeightOfRows(withIndexesChanged: update.reloaded)
                        tableView.reloadData(forRowIndexes: update.reloaded, columnIndexes: IndexSet(integer: 0))
                    }
                }
            }
        }
        if atBottom { scrollToBottom() }
        scheduleWarmup()
        refreshSelectionHighlight()
    }

    // MARK: - Scroll geometry

    private var clip: NSClipView { scrollView.contentView }

    /// Distance from the bottom of the visible area to the bottom of the content (0 when at bottom).
    private var bottomGap: CGFloat {
        let docH = tableView.frame.height
        return (docH + scrollView.contentInsets.bottom) - clip.bounds.maxY
    }

    var isAtBottom: Bool { bottomGap <= Self.bottomTolerance }

    func scrollToBottom() {
        view.layoutSubtreeIfNeeded()
        let docH = tableView.frame.height
        let y = docH + scrollView.contentInsets.bottom - clip.bounds.height
        withoutAnimation {
            clip.setBoundsOrigin(NSPoint(x: 0, y: max(-scrollView.contentInsets.top, y)))
            scrollView.reflectScrolledClipView(clip)
        }
        wasAtBottom = true
    }

    private func maintainingBottomDistance(unless skip: Bool, _ mutate: () -> Void) {
        let gap = bottomGap
        mutate()
        guard !skip else { return }
        view.layoutSubtreeIfNeeded()
        let docH = tableView.frame.height
        let y = docH + scrollView.contentInsets.bottom - gap - clip.bounds.height
        withoutAnimation {
            clip.setBoundsOrigin(NSPoint(x: 0, y: max(-scrollView.contentInsets.top, y)))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        body()
        NSAnimationContext.endGrouping()
        CATransaction.commit()
    }

    @objc private func boundsChanged() {
        wasAtBottom = isAtBottom
        if !view.inLiveResize {
            let minY = clip.bounds.minY + scrollView.contentInsets.top
            if minY < clip.bounds.height * 1.5 { loadOlderIfNeeded() }
            if rows.hasNewer, bottomGap < clip.bounds.height * 1.5 { loadNewerIfNeeded() }
        }
        scheduleWarmup()
    }

    // MARK: - Paging

    private func loadOlderIfNeeded() {
        guard !loadingOlder, rows.hasOlder, let loader, let oldest = rows.oldestSortKey else { return }
        loadingOlder = true
        let snapshotJid = rows.chatJid
        let w = width
        let own = ownJid, peer = peerName
        Task { [weak self] in
            let state = Signposts.poi.beginInterval("LoadOlder", id: Signposts.poi.makeSignpostID())
            defer { Signposts.poi.endInterval("LoadOlder", state) }
            do {
                let page = try await loader.older(before: oldest, limit: 80)
                var probe = ChatRows(chatJid: snapshotJid, isGroupChat: ChatKind(jid: snapshotJid) == .group)
                probe.replace(with: page)
                let computed = await Task.detached(priority: .userInitiated) {
                    Self.computePlans(probe, width: w, ownJid: own, peerName: peer)
                }.value
                guard let self, self.rows.chatJid == snapshotJid else { return }
                self.loadingOlder = false
                // Plans from the probe have no neighbour context at the seam; those rows get re-planned lazily.
                for (id, p) in computed { self.plans[id] = p }
                let update = self.rows.prepend(page)
                self.applyUpdate(update, scrollToBottomIfWasAtBottom: false)
            } catch {
                self?.loadingOlder = false
                Signposts.log.error("older page failed: \(error)")
            }
        }
    }

    private func loadNewerIfNeeded() {
        guard !loadingNewer, rows.hasNewer, let loader, let newest = rows.newestSortKey else { return }
        loadingNewer = true
        let snapshotJid = rows.chatJid
        Task { [weak self] in
            do {
                let page = try await loader.newer(after: newest, limit: 80)
                guard let self, self.rows.chatJid == snapshotJid else { return }
                self.loadingNewer = false
                let update = self.rows.append(page)
                self.applyUpdate(update, scrollToBottomIfWasAtBottom: false)
            } catch {
                self?.loadingNewer = false
            }
        }
    }

    /// Scrolls to `messageId`, loading a window around it if it is not loaded.
    func jump(to messageId: String) {
        if let row = rows.rowIndex[messageId] {
            scrollAndFlash(row: row)
            return
        }
        guard let loader else { return }
        let jid = rows.chatJid
        Task { [weak self] in
            guard let page = try? await loader.around(messageId: messageId, limit: 80), let self, self.rows.chatJid == jid else { return }
            self.rows.replace(with: page)
            self.plans = [:]
            self.withoutAnimation { self.tableView.reloadData() }
            self.view.layoutSubtreeIfNeeded()
            if let row = self.rows.rowIndex[messageId] { self.scrollAndFlash(row: row) }
        }
    }

    private func scrollAndFlash(row: Int) {
        let rect = tableView.rect(ofRow: row)
        let target = rect.midY - clip.bounds.height / 2
        withoutAnimation {
            clip.setBoundsOrigin(NSPoint(x: 0, y: max(-scrollView.contentInsets.top, target)))
            scrollView.reflectScrolledClipView(clip)
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: - Thumbnail warm-up

    private var warmupScheduled = false

    private func scheduleWarmup() {
        guard !warmupScheduled else { return }
        warmupScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.warmupScheduled = false
            self?.runWarmup()
        }
    }

    private func runWarmup() {
        warmupTask?.cancel()
        guard tableView.numberOfRows > 0 else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        let lo = max(0, visible.location - 12)
        let hi = min(tableView.numberOfRows, visible.location + visible.length + 12)
        guard lo < hi else { return }
        var items: [MessageItem] = []
        for r in lo..<hi {
            if let item = rows.item(atRow: r), item.media != nil, !item.message.revoked { items.append(item) }
        }
        guard !items.isEmpty else { return }
        let media = client.media
        warmupTask = Task(priority: .userInitiated) {
            let state = Signposts.poi.beginInterval("ThumbWarmup", id: Signposts.poi.makeSignpostID())
            defer { Signposts.poi.endInterval("ThumbWarmup", state) }
            for item in items {
                if Task.isCancelled { return }
                await media.autoDownloadIfNeeded(item)
                if let thumb = item.media?.jpegThumbnail, !thumb.isEmpty {
                    _ = await ThumbnailCache.shared.image(key: LayoutPlanner.thumbKey(item), source: .data(thumb), maxPixelSize: 320)
                }
            }
        }
    }

    private func startProgressObservation() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let center = self.client.media.progress
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = center.fractions
                    } onChange: {
                        c.resume()
                    }
                }
                self.pushProgressToVisibleCells()
            }
        }
    }

    private func pushProgressToVisibleCells() {
        let center = client.media.progress
        tableView.enumerateAvailableRowViews { rowView, _ in
            guard let cell = rowView.view(atColumn: 0) as? MessageCell, let media = cell.item?.media else { return }
            cell.setDownloadFraction(center.fraction(for: media))
        }
    }

    // MARK: - Selection & keys

    private func refreshSelectionHighlight() {
        let selected = tableView.selectedRow
        tableView.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? MessageCell)?.isRowSelected = row == selected
        }
    }

    var selectedItem: MessageItem? {
        tableView.selectedRow >= 0 ? rows.item(atRow: tableView.selectedRow) : nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {  // Esc
            actions?.escapeFromList()
            return true
        }
        if event.keyCode == 49 {  // Space
            quickLookSelection()
            return true
        }
        if event.keyCode == 36, let item = selectedItem {  // Return: open media
            open(item)
            return true
        }
        if let chars = event.characters, !chars.isEmpty, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let scalar = chars.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F {
            actions?.typeToCompose(chars)
            return true
        }
        return false
    }

    // MARK: - Media opening & Quick Look

    func open(_ item: MessageItem) {
        guard let media = item.media, !item.message.revoked else { return }
        if media.downloadState == .downloaded, let path = media.localPath {
            quickLook(URL(filePath: path), item: item)
            return
        }
        let store = client.media
        Task {
            do {
                let url = try await store.download(media)
                if item.message.kind == .video || item.message.kind == .document {
                    self.quickLook(url, item: item)
                }
            } catch {
                Signposts.log.error("download failed: \(error)")
            }
        }
    }

    func quickLookSelection() {
        guard let item = selectedItem else { return }
        if let media = item.media, media.downloadState == .downloaded, let path = media.localPath {
            quickLook(URL(filePath: path), item: item)
        } else {
            open(item)
        }
    }

    private func quickLook(_ url: URL, item: MessageItem) {
        previewItems = rows.messages.compactMap { m -> PreviewItem? in
            guard let media = m.media, media.downloadState == .downloaded, let p = media.localPath, m.message.kind != .audio, m.message.kind != .voice else { return nil }
            return PreviewItem(url: URL(filePath: p), title: media.fileName ?? LayoutPlanner.timeText(m.message.timestamp), messageId: m.id)
        }
        previewIndex = previewItems.firstIndex { $0.messageId == item.id } ?? 0
        if previewItems.isEmpty { previewItems = [PreviewItem(url: url, title: "", messageId: item.id)] }
        view.window?.makeFirstResponder(tableView)
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, panel.dataSource === self {
            panel.reloadData()
            panel.currentPreviewItemIndex = previewIndex
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            panel.currentPreviewItemIndex = previewIndex
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    // MARK: - Context menu

    private func menu(for item: MessageItem) -> NSMenu {
        let menu = NSMenu()
        let m = item.message
        let own = m.fromMe
        if !m.revoked, m.kind != .system, !m.isPending {
            menu.addItem(withTitle: "Reply", action: #selector(menuReply(_:)), keyEquivalent: "").representedObject = item
            let react = NSMenuItem(title: "React", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for e in ["👍", "❤️", "😂", "😮", "😢", "🙏"] {
                let mi = NSMenuItem(title: e, action: #selector(menuReact(_:)), keyEquivalent: "")
                mi.representedObject = (item, e)
                mi.target = self
                sub.addItem(mi)
            }
            react.submenu = sub
            menu.addItem(react)
        }
        if let t = m.text, !t.isEmpty, !m.revoked {
            menu.addItem(withTitle: "Copy", action: #selector(menuCopy(_:)), keyEquivalent: "").representedObject = item
        }
        if let media = item.media, media.downloadState == .downloaded, let path = media.localPath, !m.revoked {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quick Look", action: #selector(menuQuickLook(_:)), keyEquivalent: "").representedObject = item
            menu.addItem(withTitle: "Show in Finder", action: #selector(menuReveal(_:)), keyEquivalent: "").representedObject = item
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.submenu = openWithMenu(for: URL(filePath: path))
            menu.addItem(openWith)
            menu.addItem(withTitle: "Save As…", action: #selector(menuSaveAs(_:)), keyEquivalent: "").representedObject = item
        } else if item.media != nil, !m.revoked, m.kind != .sticker {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Download", action: #selector(menuDownload(_:)), keyEquivalent: "").representedObject = item
        }
        if own, !m.revoked, !m.isPending, m.status != .failed {
            menu.addItem(.separator())
            if m.kind == .text {
                menu.addItem(withTitle: "Edit", action: #selector(menuEdit(_:)), keyEquivalent: "").representedObject = item
            }
            menu.addItem(withTitle: "Delete for Everyone", action: #selector(menuRevoke(_:)), keyEquivalent: "").representedObject = item
        }
        if m.status == .failed {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Retry", action: #selector(menuRetry(_:)), keyEquivalent: "").representedObject = item
        }
        for mi in menu.items where mi.target == nil && mi.action != nil { mi.target = self }
        return menu
    }

    private func openWithMenu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        for app in apps.prefix(12) {
            let name = FileManager.default.displayName(atPath: app.path)
            let mi = NSMenuItem(title: app == defaultApp ? "\(name) (default)" : name, action: #selector(menuOpenWith(_:)), keyEquivalent: "")
            mi.representedObject = (url, app)
            mi.target = self
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            mi.image = icon
            menu.addItem(mi)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "No applications", action: nil, keyEquivalent: "") }
        return menu
    }

    @objc private func menuReply(_ sender: NSMenuItem) { if let item = sender.representedObject as? MessageItem { actions?.reply(to: item) } }
    @objc private func menuReact(_ sender: NSMenuItem) {
        if let (item, e) = sender.representedObject as? (MessageItem, String) { actions?.toggleReaction(e, on: item) }
    }
    @objc private func menuCopy(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MessageItem, let t = item.message.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }
    @objc private func menuQuickLook(_ sender: NSMenuItem) { if let item = sender.representedObject as? MessageItem { open(item) } }
    @objc private func menuReveal(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MessageItem, let p = item.media?.localPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: p)])
    }
    @objc private func menuOpenWith(_ sender: NSMenuItem) {
        guard let (url, app) = sender.representedObject as? (URL, URL) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    @objc private func menuSaveAs(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MessageItem, let p = item.media?.localPath, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.media?.fileName ?? URL(filePath: p).lastPathComponent
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let dest = panel.url else { return }
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: URL(filePath: p), to: dest)
        }
    }
    @objc private func menuDownload(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MessageItem, let media = item.media else { return }
        let store = client.media
        Task { _ = try? await store.download(media) }
    }
    @objc private func menuEdit(_ sender: NSMenuItem) { if let item = sender.representedObject as? MessageItem { actions?.edit(item) } }
    @objc private func menuRevoke(_ sender: NSMenuItem) { if let item = sender.representedObject as? MessageItem { actions?.revoke(item) } }
    @objc private func menuRetry(_ sender: NSMenuItem) { if let item = sender.representedObject as? MessageItem { actions?.retry(item) } }
}

// MARK: - Data source / delegate

extension MessageListController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows.row(at: row) {
        case .day: return M.daySeparatorHeight
        case .unread: return M.unreadSeparatorHeight
        case .message(let id): return plan(for: id).rowHeight
        case nil: return 1
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows.row(at: row) {
        case .day(let ts):
            let id = NSUserInterfaceItemIdentifier("day")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? DaySeparatorCell ?? {
                let c = DaySeparatorCell()
                c.identifier = id
                return c
            }()
            cell.configure(dayStart: ts)
            return cell
        case .unread:
            let id = NSUserInterfaceItemIdentifier("unread")
            return tableView.makeView(withIdentifier: id, owner: nil) as? UnreadSeparatorCell ?? {
                let c = UnreadSeparatorCell()
                c.identifier = id
                return c
            }()
        case .message(let mid):
            guard let item = rows.item(id: mid) else { return nil }
            // One reuse pool per kind keeps text views and media layers with rows that need them.
            let id = NSUserInterfaceItemIdentifier("msg-\(item.message.kind)")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? MessageCell ?? {
                let c = MessageCell(frame: .zero)
                c.identifier = id
                c.delegate = self
                return c
            }()
            cell.configure(item: item, plan: plan(for: mid))
            cell.isRowSelected = tableView.selectedRow == row
            cell.setDownloadFraction(item.media.flatMap { client.media.progress.fraction(for: $0) })
            return cell
        case nil:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .message = rows.row(at: row) { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshSelectionHighlight()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let view = tableView.makeView(withIdentifier: id, owner: nil) as? PlainRowView ?? {
            let v = PlainRowView()
            v.identifier = id
            return v
        }()
        return view
    }
}

/// No system selection or hover drawing.
final class PlainRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }
}

// MARK: - Cell delegate

extension MessageListController: MessageCellDelegate {
    var mediaStore: MediaStore { client.media }

    func cell(_ cell: MessageCell, didClickQuote targetId: String) { jump(to: targetId) }

    func cell(_ cell: MessageCell, didToggleReaction emoji: String, on item: MessageItem) {
        actions?.toggleReaction(emoji, on: item)
    }

    func cell(_ cell: MessageCell, didClickMedia item: MessageItem) { open(item) }

    func cell(_ cell: MessageCell, didClickRetry item: MessageItem) { actions?.retry(item) }

    func cell(_ cell: MessageCell, menuFor item: MessageItem) -> NSMenu? { menu(for: item) }

    func cell(_ cell: MessageCell, beginDragOf fileURL: URL, with event: NSEvent) {
        let provider = NSFilePromiseProvider(fileType: UTType(filenameExtension: fileURL.pathExtension)?.identifier ?? UTType.data.identifier,
                                             delegate: FilePromiseSource(url: fileURL))
        let item = NSDraggingItem(pasteboardWriter: provider)
        let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
        let p = cell.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48), contents: icon)
        cell.beginDraggingSession(with: [item], event: event, source: self)
    }
}

/// Copies an already-downloaded file to wherever the drag lands.
final class FilePromiseSource: NSObject, NSFilePromiseProviderDelegate, Sendable {
    let url: URL
    private let queue = OperationQueue()

    init(url: URL) { self.url = url }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { url.lastPathComponent }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo destination: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
}

extension MessageListController: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

// MARK: - Quick Look

final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    let messageId: String

    init(url: URL, title: String, messageId: String) {
        previewItemURL = url
        previewItemTitle = title
        self.messageId = messageId
    }
}

extension MessageListController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewItems[index]
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let pi = item as? PreviewItem, let row = rows.rowIndex[pi.messageId],
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCell, let plan = cell.plan else { return .zero }
        var frame = plan.bubble
        if case .media(let m) = plan.content { frame = m.frame }
        let inWindow = cell.convert(frame, to: nil)
        return cell.window?.convertToScreen(inWindow) ?? .zero
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Let ↑/↓ fall through to the table so the selection follows the preview.
        false
    }
}
