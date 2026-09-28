import AppKit
import Quartz
import Synchronization
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
    /// ↓ past the newest message.
    func returnToCompose()
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
    /// Bumped on every chat switch; async work captured under an older generation is dropped.
    private var generation = 0
    /// Bumped whenever `rows` is replaced or mutated; background plan batches validate against it.
    private var rowsVersion = 0
    /// Every mutation of `rows` (feed changes, paging, jumps, reloads) runs through this serial queue,
    /// so plans can be computed off-main against a snapshot that is still current when installed.
    private var ops: AsyncStream<ListOp>.Continuation?
    private var pipelineTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var loadingOlder = false
    private var loadingNewer = false
    private var warmupTask: Task<Void, Never>?
    private var recomputeTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var bottomInset: CGFloat = 0
    /// Extra room under the toolbar for views floating over the top of the list (the chat header).
    var topAccessoryInset: CGFloat = 0 {
        didSet { if topAccessoryInset != oldValue { view.needsLayout = true } }
    }
    private var needsInitialScroll = false
    private var bottomGapBeforeLayout: CGFloat = 0
    private var wasAtBottom = true
    private var pendingFlashId: String?
    private var highlightedRow: Int?
    private var previewItems: [PreviewItem] = []
    private var previewIndex = 0
    private var openedPreviewPanel = false

    private enum ListOp: Sendable {
        case change(MessageChange)
        case older
        case newer
        case jump(String)
    }

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
        pipelineTask?.cancel()
        ops?.finish()
        warmupTask?.cancel()
        recomputeTask?.cancel()
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
        let top = view.safeAreaInsets.top + M.listTopInset + topAccessoryInset
        if scrollView.contentInsets.top != top || scrollView.contentInsets.bottom != bottomInset {
            // The scroller track already follows contentInsets; scrollerInsets would inset it twice.
            scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: bottomInset, right: 0)
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
        if atBottom { scrollToBottom() }
    }

    var measurementWidth: CGFloat {
        let w = floor(scrollView.contentView.bounds.width)
        return w > 0 ? w : max(320, floor(view.bounds.width))
    }

    // MARK: - Chat lifecycle

    func clear() {
        resetForChatSwitch()
        rows = ChatRows(chatJid: "", isGroupChat: false)
        rowsVersion &+= 1
        plans = [:]
        loader = nil
        tableView.reloadData()
    }

    /// Cancels everything tied to the previous chat.
    private func resetForChatSwitch() {
        generation &+= 1
        feedTask?.cancel()
        feedTask = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        ops?.finish()
        ops = nil
        warmupTask?.cancel()
        recomputeTask?.cancel()
        recomputeTask = nil
        loadingOlder = false
        loadingNewer = false
        closePreviewPanel()
    }

    /// Installs a prepared window and renders it in the current runloop turn.
    func show(_ prepared: PreparedChat, changes: AsyncStream<MessageChange>) {
        let state = Signposts.poi.beginInterval("OpenChatRender", id: Signposts.poi.makeSignpostID())
        defer { Signposts.poi.endInterval("OpenChatRender", state) }
        resetForChatSwitch()
        rows = prepared.rows
        rowsVersion &+= 1
        ownJid = prepared.ownJid
        peerName = prepared.peerName
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
        startPipeline(changes: changes)
    }

    private func startPipeline(changes: AsyncStream<MessageChange>) {
        let (stream, continuation) = AsyncStream.makeStream(of: ListOp.self)
        ops = continuation
        feedTask = Task {
            for await change in changes {
                if Task.isCancelled { break }
                continuation.yield(.change(change))
            }
        }
        let gen = generation
        pipelineTask = Task { [weak self] in
            for await op in stream {
                if Task.isCancelled { return }
                // `self` is only held while one op runs, never across the wait for the next one.
                guard let self, self.generation == gen else { return }
                await self.run(op, gen: gen)
            }
        }
    }

    #if DEBUG
    /// Harness: plan cache misses served synchronously on main.
    private(set) var debugSyncPlanFallbacks = 0
    /// Harness: feed a `.reload` through the pipeline as the change feed would.
    func debugInjectReload() { ops?.yield(.change(.reload)) }
    var debugLoadingFlags: (older: Bool, newer: Bool) { (loadingOlder, loadingNewer) }
    #endif

    private func run(_ op: ListOp, gen: Int) async {
        switch op {
        case .change(.reload): await runReload(gen: gen)
        case .change(let change): await runChange(change, gen: gen)
        case .older: await runLoadOlder(gen: gen)
        case .newer: await runLoadNewer(gen: gen)
        case .jump(let id): await runJump(to: id, gen: gen)
        }
    }

    // MARK: - Plans

    /// Lookup for `heightOfRow` / `viewFor`. Plans are precomputed off-main by the pipeline; a miss
    /// (rows scrolled in during live resize, or a width change racing a batch) is computed here as a
    /// last resort and signposted so it shows up in Instruments.
    private func plan(for id: String) -> LayoutPlan {
        if let p = plans[id], abs(p.width - width) < 0.5 { return p }
        #if DEBUG
        debugSyncPlanFallbacks += 1
        #endif
        let state = Signposts.poi.beginInterval("PlanSyncFallback", id: Signposts.poi.makeSignpostID())
        defer { Signposts.poi.endInterval("PlanSyncFallback", state) }
        guard let i = rows.messageIndex[id] else {
            // Should not happen; a zero-height plan keeps the table consistent.
            return plans[id] ?? LayoutPlanner.plan(rows.messages[0], rows.context(forMessageAt: 0, width: width, ownJid: ownJid, peerName: peerName))
        }
        let ctx = rows.context(forMessageAt: i, width: width, ownJid: ownJid, peerName: peerName)
        let p = LayoutPlanCache.shared.plan(for: rows.messages[i], context: ctx)
        plans[id] = p
        return p
    }

    /// Computes plans for `ids` (all messages when nil) in `rows` at `width`. Runs off the main thread.
    private nonisolated static func computePlans(_ rows: ChatRows, ids: Set<String>?, width: CGFloat, ownJid: String?, peerName: String?) -> [String: LayoutPlan] {
        var out: [String: LayoutPlan] = [:]
        out.reserveCapacity(ids?.count ?? rows.messages.count)
        func add(_ i: Int) {
            let ctx = rows.context(forMessageAt: i, width: width, ownJid: ownJid, peerName: peerName)
            out[rows.messages[i].id] = LayoutPlanCache.shared.plan(for: rows.messages[i], context: ctx)
        }
        if let ids {
            for id in ids { if let i = rows.messageIndex[id] { add(i) } }
        } else {
            for i in rows.messages.indices { add(i) }
        }
        return out
    }

    /// Off-main plan computation for a pipeline op. Retries once if the width moved meanwhile, so
    /// the installed plans match the width `heightOfRow` will ask for.
    private func plansOffMain(_ rows: ChatRows, ids: Set<String>?) async -> [String: LayoutPlan] {
        var result: [String: LayoutPlan] = [:]
        for _ in 0..<2 {
            let w = width, own = ownJid, peer = peerName
            result = await Task.detached(priority: .userInitiated) {
                Self.computePlans(rows, ids: ids, width: w, ownJid: own, peerName: peer)
            }.value
            if abs(width - w) < 0.5 { break }
        }
        return result
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
        recomputeTask?.cancel()
        let snapshot = rows
        let version = rowsVersion
        let gen = generation
        let w = width
        let own = ownJid
        let peer = peerName
        recomputeTask = Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) {
                Self.computePlans(snapshot, ids: nil, width: w, ownJid: own, peerName: peer)
            }.value
            guard !Task.isCancelled, let self, self.generation == gen, self.width == w else { return }
            if self.rowsVersion == version {
                for (id, p) in computed { self.plans[id] = p }
            } else {
                // Rows changed while computing (edit, revoke, paging): only install plans whose content
                // and row context are unchanged; the pipeline already planned the rest.
                for (id, p) in computed {
                    guard let i = self.rows.messageIndex[id], let si = snapshot.messageIndex[id],
                          self.rows.messages[i] == snapshot.messages[si],
                          self.rows.context(forMessageAt: i, width: w, ownJid: self.ownJid, peerName: self.peerName)
                            == snapshot.context(forMessageAt: si, width: w, ownJid: own, peerName: peer) else { continue }
                    self.plans[id] = p
                }
            }
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

    // MARK: - Applying changes (pipeline ops)

    private func runChange(_ change: MessageChange, gen: Int) async {
        let state = Signposts.poi.beginInterval("ApplyChange", id: Signposts.poi.makeSignpostID())
        defer { Signposts.poi.endInterval("ApplyChange", state) }
        var next = rows
        let update = next.apply(change)
        guard !update.isEmpty else {
            if next.messages != rows.messages { rows = next; rowsVersion &+= 1 }
            return
        }
        var ids = Set(change.ids)
        for i in update.inserted.union(update.reloaded) { if case .message(let id) = next.row(at: i) { ids.insert(id) } }
        let computed = await plansOffMain(next, ids: ids)
        guard generation == gen else { return }
        let atBottom = isAtBottom
        rows = next
        rowsVersion &+= 1
        for id in change.ids where rows.messageIndex[id] == nil { plans[id] = nil }
        if case .replace(let old, let item) = change, old != item.id { plans[old] = nil }
        for (id, p) in computed { plans[id] = p }
        applyUpdate(update, scrollToBottomIfWasAtBottom: atBottom)
    }

    /// `.reload`: re-fetch the window around what the user is looking at (or the newest page when
    /// pinned to the bottom), plan it off-main, then swap it in keeping the visible position.
    private func runReload(gen: Int) async {
        guard let loader else { return }
        let state = Signposts.poi.beginInterval("ReloadWindow", id: Signposts.poi.makeSignpostID())
        defer { Signposts.poi.endInterval("ReloadWindow", state) }
        let limit = min(max(rows.messages.count, ChatOpenPreloader.initialPageSize), 300)
        let anchor = isAtBottom ? nil : topVisibleAnchor()
        let page: MessagePage
        do {
            if let anchor, let around = try await loader.around(messageId: anchor.id, limit: limit) {
                page = around
            } else {
                page = try await loader.initial(limit: limit)
            }
        } catch {
            Signposts.log.error("reload failed: \(error)")
            return
        }
        guard generation == gen else { return }
        var next = rows
        next.replace(with: page)
        let computed = await plansOffMain(next, ids: nil)
        guard generation == gen else { return }

        // Re-sample: the user may have scrolled while the page loaded.
        let atBottom = isAtBottom
        let liveAnchor = atBottom ? nil : topVisibleAnchor()
        let gap = bottomGap
        rows = next
        rowsVersion &+= 1
        plans = computed
        withoutAnimation { tableView.reloadData() }
        view.layoutSubtreeIfNeeded()
        if atBottom {
            scrollToBottom()
        } else if let liveAnchor, let row = rows.rowIndex[liveAnchor.id] {
            setClipOrigin(y: tableView.rect(ofRow: row).minY - liveAnchor.offset)
        } else {
            setClipOrigin(y: tableView.frame.height + scrollView.contentInsets.bottom - gap - clip.bounds.height)
        }
        scheduleWarmup()
        refreshSelectionHighlight()
    }

    /// The first message row at least partly visible, and its top's offset from the clip's top.
    private func topVisibleAnchor() -> (id: String, offset: CGFloat)? {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return nil }
        for r in visible.location..<(visible.location + visible.length) {
            if case .message(let id) = rows.row(at: r) {
                return (id, tableView.rect(ofRow: r).minY - clip.bounds.minY)
            }
        }
        return nil
    }

    private func setClipOrigin(y: CGFloat) {
        withoutAnimation {
            clip.setBoundsOrigin(NSPoint(x: 0, y: max(-scrollView.contentInsets.top, y)))
            scrollView.reflectScrolledClipView(clip)
        }
        wasAtBottom = isAtBottom
    }

    /// `keepTop`: rows were appended below the viewport (newer page); the flipped table keeps the
    /// visible rows in place by itself, so the bottom distance must not be preserved.
    private func applyUpdate(_ update: ChatRows.Update, scrollToBottomIfWasAtBottom atBottom: Bool, keepTop: Bool = false) {
        guard !update.isEmpty else { return }
        maintainingBottomDistance(unless: atBottom || keepTop) {
            withoutAnimation {
                if update.reloadAll {
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
        guard !loadingOlder, rows.hasOlder, loader != nil, let ops else { return }
        loadingOlder = true
        ops.yield(.older)
    }

    private func loadNewerIfNeeded() {
        guard !loadingNewer, rows.hasNewer, loader != nil, let ops else { return }
        loadingNewer = true
        ops.yield(.newer)
    }

    private func runLoadOlder(gen: Int) async {
        defer { if generation == gen { loadingOlder = false } }
        guard rows.hasOlder, let loader, let oldest = rows.oldestSortKey else { return }
        let state = Signposts.poi.beginInterval("LoadOlder", id: Signposts.poi.makeSignpostID())
        defer { Signposts.poi.endInterval("LoadOlder", state) }
        do {
            let page = try await loader.older(before: oldest, limit: 80)
            guard generation == gen else { return }
            await installPage(gen: gen, keepTop: false) { $0.prepend(page) }
        } catch {
            Signposts.log.error("older page failed: \(error)")
        }
    }

    private func runLoadNewer(gen: Int) async {
        defer { if generation == gen { loadingNewer = false } }
        guard rows.hasNewer, let loader, let newest = rows.newestSortKey else { return }
        do {
            let page = try await loader.newer(after: newest, limit: 80)
            guard generation == gen else { return }
            await installPage(gen: gen, keepTop: true) { $0.append(page) }
        } catch {
            Signposts.log.error("newer page failed: \(error)")
        }
    }

    /// Applies a prepend/append to a copy, plans the new rows and the seam neighbours off-main, then
    /// installs both keeping the visible rows in place.
    private func installPage(gen: Int, keepTop: Bool, _ mutate: (inout ChatRows) -> ChatRows.Update) async {
        var next = rows
        let update = mutate(&next)
        guard !update.isEmpty else {
            rows = next  // hasOlder / hasNewer flags
            return
        }
        var ids = Set<String>()
        for i in update.inserted.union(update.reloaded) { if case .message(let id) = next.row(at: i) { ids.insert(id) } }
        let computed = await plansOffMain(next, ids: ids)
        guard generation == gen else { return }
        rows = next
        rowsVersion &+= 1
        for (id, p) in computed { plans[id] = p }
        applyUpdate(update, scrollToBottomIfWasAtBottom: false, keepTop: keepTop)
    }

    /// Scrolls to `messageId`, loading a window around it if it is not loaded.
    func jump(to messageId: String) {
        if let row = rows.rowIndex[messageId] {
            scrollAndFlash(row: row)
            return
        }
        ops?.yield(.jump(messageId))
    }

    private func runJump(to messageId: String, gen: Int) async {
        if let row = rows.rowIndex[messageId] {
            scrollAndFlash(row: row)
            return
        }
        guard let loader, let page = try? await loader.around(messageId: messageId, limit: 80), generation == gen else { return }
        var next = rows
        next.replace(with: page)
        let computed = await plansOffMain(next, ids: nil)
        guard generation == gen else { return }
        rows = next
        rowsVersion &+= 1
        plans = computed
        withoutAnimation { tableView.reloadData() }
        view.layoutSubtreeIfNeeded()
        scheduleWarmup()
        if let row = rows.rowIndex[messageId] { scrollAndFlash(row: row) }
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
        let center = client.media.progress
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                await Self.nextChange(of: center)
                if Task.isCancelled { return }
                // No strong `self` across the wait: a released controller ends the loop here.
                guard let controller = self else { return }
                controller.pushProgressToVisibleCells()
            }
        }
    }

    /// Suspends until `center.fractions` changes or the task is cancelled.
    private static func nextChange(of center: MediaProgressCenter) async {
        let once = ResumeOnce()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                once.install(c)
                withObservationTracking {
                    _ = center.fractions
                } onChange: {
                    once.resume()
                }
            }
        } onCancel: {
            once.resume()
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

    var hasKeyboardFocus: Bool { view.window?.firstResponder === tableView }

    func clearSelection() { tableView.deselectAll(nil) }

    /// ↑ in an empty compose: selects the newest message and takes keyboard focus.
    @discardableResult
    func selectNewestMessage() -> Bool {
        guard let row = messageRow(before: rows.count) else { return false }
        selectMessage(at: row)
        view.window?.makeFirstResponder(tableView)
        return true
    }

    private func selectMessage(at row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func messageRow(before row: Int) -> Int? {
        stride(from: row - 1, through: 0, by: -1).first { if case .message = rows.row(at: $0) { true } else { false } }
    }

    private func messageRow(after row: Int) -> Int? {
        (row + 1 ..< rows.count).first { if case .message = rows.row(at: $0) { true } else { false } }
    }

    /// Message-list keys: ↑/↓ walk messages, E edits, R reacts, ⌘R replies. A key that does not
    /// apply to the selected message shakes it.
    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let selected = tableView.selectedRow
        if mods.isEmpty, event.keyCode == 126 {  // ↑
            if selected < 0 { return selectNewestMessage() }
            if let row = messageRow(before: selected) { selectMessage(at: row) }
            return true
        }
        if mods.isEmpty, event.keyCode == 125, selected >= 0 {  // ↓
            if let row = messageRow(after: selected) {
                selectMessage(at: row)
            } else {
                clearSelection()
                actions?.returnToCompose()
            }
            return true
        }
        if let item = selectedItem {
            if mods == .command, key == "r" {
                guard ChatRows.canRespond(to: item) else { return shake(row: selected) }
                clearSelection()
                actions?.reply(to: item)
                return true
            }
            if mods.isEmpty, key == "e" {
                guard ChatRows.canEdit(item) else { return shake(row: selected) }
                clearSelection()
                actions?.edit(item)
                return true
            }
            if mods.isEmpty, key == "r" {
                guard ChatRows.canRespond(to: item) else { return shake(row: selected) }
                showReactionMenu(for: item, row: selected)
                return true
            }
        }
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
            clearSelection()
            actions?.typeToCompose(chars)
            return true
        }
        return false
    }

    /// Shakes the message at `row` to refuse a key. Returns true (the key is consumed).
    private func shake(row: Int) -> Bool {
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else {
            NSSound.beep()
            return true
        }
        cell.wantsLayer = true
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 8, -6, 6, -3, 3, 0]
        shake.duration = 0.35
        cell.layer?.add(shake, forKey: "shake")
        return true
    }

    static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    /// R: the quick reactions under the bubble; 1–6 pick, and the current one is checked.
    private func showReactionMenu(for item: MessageItem, row: Int) {
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCell,
              let bubble = cell.plan?.bubble else { return }
        let mine = item.reactions.first { $0.fromMe }?.emoji
        let menu = NSMenu()
        for (i, emoji) in Self.quickReactions.enumerated() {
            let mi = NSMenuItem(title: emoji, action: #selector(menuReact(_:)), keyEquivalent: String(i + 1))
            mi.keyEquivalentModifierMask = []
            mi.representedObject = (item, emoji)
            mi.target = self
            mi.state = emoji == mine ? .on : .off
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: bubble.minX, y: bubble.maxY + 4), in: cell)
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

    var canQuickLookSelection: Bool {
        tableView.window?.firstResponder === tableView && selectedItem?.media != nil
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
            openedPreviewPanel = true
        }
    }

    /// The preview items belong to the chat being left; close the panel rather than let it step
    /// through a list that no longer matches.
    private func closePreviewPanel() {
        previewItems = []
        previewIndex = 0
        guard openedPreviewPanel, QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return }
        openedPreviewPanel = false
        // When the chat window isn't key, QL has ended our control and the data source is nil; it
        // re-attaches on the next key change, so the panel must not outlive the old item list.
        guard panel.dataSource == nil || panel.dataSource === self else { return }
        if panel.dataSource === self { panel.reloadData() }
        if panel.isVisible { panel.orderOut(nil) }
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
        if ChatRows.canRespond(to: item) {
            menu.addItem(withTitle: "Reply", action: #selector(menuReply(_:)), keyEquivalent: "").representedObject = item
            let react = NSMenuItem(title: "React", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for e in Self.quickReactions {
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
            if ChatRows.canEdit(item) {
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
        previewItems.indices.contains(index) ? previewItems[index] : nil
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

/// Resumes a continuation exactly once, whichever of change / cancellation comes first.
private final class ResumeOnce: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<Void, Never>?, fired: Bool)>((nil, false))

    func install(_ c: CheckedContinuation<Void, Never>) {
        let fireNow = state.withLock { s -> Bool in
            if s.fired { return true }
            s.continuation = c
            return false
        }
        if fireNow { c.resume() }
    }

    func resume() {
        let c = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.fired = true
            defer { s.continuation = nil }
            return s.continuation
        }
        c?.resume()
    }
}
