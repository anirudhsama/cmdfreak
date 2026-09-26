import AppKit
import Quartz
import WAKit
import os

/// The chat content area: message list + glass compose. One instance serves every chat; `show`
/// swaps the loaded window. Mount it as the split view's content item and call `show(chatJid:)`
/// when the selection changes (call `preloader.warm` earlier when you can, e.g. on hover).
@MainActor
public final class ChatViewController: NSViewController {
    public let client: WAClient
    public let preloader: ChatOpenPreloader

    /// Esc with nothing to clear (no reply/edit bar): the shell should focus the chat list.
    public var onEscapeWithNothingToClear: (() -> Void)?
    public private(set) var chatJid: String?

    private let list: MessageListController
    private let compose = ComposeView()
    private let emptyLabel = NSTextField(labelWithString: "Select a chat")
    private var composeBottom: NSLayoutConstraint!
    private var replyTarget: MessageItem?
    private var editTarget: MessageItem?
    private var drafts: [String: String] = [:]
    private var lastComposingSent: Date = .distantPast
    private var pausedTimer: Timer?
    private var keyObservers: [NSObjectProtocol] = []
    /// The attachment tray, in order. Metadata is computed as soon as a file is staged.
    private var staged: [StagedAttachment] = []

    public init(client: WAClient, preloader: ChatOpenPreloader = .shared) {
        self.client = client
        self.preloader = preloader
        self.list = MessageListController(client: client)
        super.init(nibName: nil, bundle: nil)
        list.actions = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View

    public override func loadView() {
        let root = AttachmentDropView()
        root.wantsLayer = true
        root.onDrop = { [weak self] urls in self?.attach(urls) }
        root.acceptsDrops = { [weak self] in self?.chatJid != nil && self?.editTarget == nil }
        view = root

        addChild(list)
        list.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(list.view)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .tertiaryLabelColor
        root.addSubview(emptyLabel)

        root.addSubview(compose)
        composeBottom = compose.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        NSLayoutConstraint.activate([
            list.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.view.topAnchor.constraint(equalTo: root.topAnchor),
            list.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            compose.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            compose.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            composeBottom,
            compose.widthAnchor.constraint(lessThanOrEqualToConstant: 900),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])

        compose.onHeightChange = { [weak self] h in self?.list.setBottomInset(h) }
        compose.onSend = { [weak self] text in self?.send(text) }
        compose.onTyping = { [weak self] in self?.noteTyping() }
        compose.onEscape = { [weak self] in
            guard let self else { return }
            if !self.clearStaged() { self.onEscapeWithNothingToClear?() }
        }
        compose.onArrowUpEmpty = { [weak self] in self?.editLastOwnMessage() }
        compose.onAttach = { [weak self] in self?.attachFile() }
        compose.onPasteFiles = { [weak self] urls in self?.attach(urls) }
        compose.onRemoveAttachment = { [weak self] id in self?.removeStaged(id) }
        compose.onCancelBar = { [weak self] in
            self?.replyTarget = nil
            self?.editTarget = nil
        }
        setChatVisible(false)
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        observeWindowKey()
        updateFocus()
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        client.setFocus(chatJid: nil, windowIsKey: false)
    }

    private func observeWindowKey() {
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyObservers = []
        guard let window = view.window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFocus() }
            })
        }
    }

    private func updateFocus() {
        client.setFocus(chatJid: chatJid, windowIsKey: view.window?.isKeyWindow ?? false)
    }

    private func setChatVisible(_ visible: Bool) {
        list.view.isHidden = !visible
        compose.isHidden = !visible
        emptyLabel.isHidden = visible
    }

    // MARK: - Public API

    /// Shows `chatJid` (nil clears the view). If the preloader already prepared this chat at the
    /// current width the first frame is synchronous; otherwise one async hop.
    public func show(chatJid: String?) {
        guard chatJid != self.chatJid else { return }
        if let old = self.chatJid { drafts[old] = compose.text }
        self.chatJid = chatJid
        replyTarget = nil
        editTarget = nil
        clearStaged()
        compose.setBar(nil)
        compose.text = chatJid.flatMap { drafts[$0] } ?? ""
        pausedTimer?.invalidate()

        guard let chatJid else {
            list.clear()
            setChatVisible(false)
            updateFocus()
            return
        }
        setChatVisible(true)
        view.layoutSubtreeIfNeeded()
        let state = Signposts.poi.beginInterval("OpenChat", id: Signposts.poi.makeSignpostID(), "\(chatJid, privacy: .private)")
        // Subscribe before loading so nothing between the read and the first frame is lost.
        let changes = client.feed.changes(for: chatJid)
        let width = list.measurementWidth
        if let prepared = preloader.takePrepared(chatJid: chatJid, width: width) {
            list.show(prepared, changes: changes)
            Signposts.poi.endInterval("OpenChat", state, "prepared")
            didOpen(chatJid)
            return
        }
        list.clear()
        let preloader = self.preloader
        let client = self.client
        Task { [weak self] in
            do {
                let prepared = try await preloader.prepare(chatJid: chatJid, width: width, client: client)
                guard let self, self.chatJid == chatJid else { return }
                _ = self.preloader.takePrepared(chatJid: chatJid, width: width)
                self.list.show(prepared, changes: changes)
                Signposts.poi.endInterval("OpenChat", state, "loaded")
                self.didOpen(chatJid)
            } catch {
                Signposts.log.error("open chat failed: \(error)")
                Signposts.poi.endInterval("OpenChat", state, "failed")
            }
        }
    }

    private func didOpen(_ chatJid: String) {
        updateFocus()
        if view.window?.isKeyWindow ?? false {
            Task { await client.openChat(chatJid) }
        }
    }

    /// Awaitable variant for shells that want a guaranteed synchronous first frame.
    public func open(chatJid: String) async {
        guard chatJid != self.chatJid else { return }
        _ = try? await preloader.prepare(chatJid: chatJid, width: list.measurementWidth, client: client)
        show(chatJid: chatJid)
    }

    public func focusCompose() {
        guard chatJid != nil else { return }
        compose.focus()
    }

    /// "Type in list → compose": inserts the typed text and focuses the editor.
    public func insertComposeText(_ text: String) {
        guard chatJid != nil else { return }
        compose.insert(text)
    }

    /// Esc: clears reply/edit state. Returns false when there was nothing to clear.
    @discardableResult
    public func handleEscape() -> Bool {
        compose.handleEscape() || clearStaged()
    }

    /// Esc menu title while a reply or edit is pending.
    public var transientStateTitle: String? {
        if editTarget != nil { return "Cancel Edit" }
        if replyTarget != nil { return "Cancel Reply" }
        return nil
    }

    /// Space is only claimed when the message list has focus and a media message is selected.
    public var canQuickLookSelection: Bool { list.canQuickLookSelection }

    /// Space with the list focused: Quick Look on the selected media message.
    public func quickLookSelection() {
        list.quickLookSelection()
    }

    /// ⌘⇧O and the attach button: pick files into the attachment tray.
    public func attachFile() {
        guard chatJid != nil, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Photos, videos and GIFs are sent as media; anything else as a document."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.attach(panel.urls)
        }
    }

    /// Stages files in the attachment tray (attach button, paste, drop) and starts computing
    /// their metadata off the main thread.
    public func attach(_ urls: [URL]) {
        guard chatJid != nil, !urls.isEmpty else { return }
        if editTarget != nil { compose.handleEscape() }
        for url in urls where !url.hasDirectoryPath {
            let task = Task.detached(priority: .userInitiated) { try await OutgoingMediaPreparer.prepare(url) }
            let item = StagedAttachment(source: url, task: task)
            staged.append(item)
            Task { [weak self] in
                let result = await task.result
                self?.finishPreparing(item.id, result)
            }
        }
        refreshTray()
        compose.focus()
    }

    private func finishPreparing(_ id: UUID, _ result: Result<PreparedAttachment, any Error>) {
        guard let i = staged.firstIndex(where: { $0.id == id }) else { return }
        staged[i].result = result
        refreshTray()
    }

    private func removeStaged(_ id: UUID) {
        guard let i = staged.firstIndex(where: { $0.id == id }) else { return }
        staged.remove(at: i).discard()
        refreshTray()
    }

    /// Empties the tray. Returns false when it was already empty.
    @discardableResult
    private func clearStaged() -> Bool {
        guard !staged.isEmpty else { return false }
        staged.forEach { $0.discard() }
        staged = []
        refreshTray()
        return true
    }

    private func refreshTray() {
        compose.setAttachments(staged.map(\.trayItem))
    }

    public var isComposeFocused: Bool {
        view.window?.firstResponder === compose.textView
    }

    // Internal hooks for the debug harness.
    var listController: MessageListController { list }
    func debugSend() { send(compose.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    func debugArrowUp() { editLastOwnMessage() }
    var debugBar: ComposeView.Bar? { compose.bar }
    var debugComposeText: String { compose.text }

    // MARK: - Sending

    private func send(_ text: String) {
        guard let chatJid else { return }
        let state = Signposts.poi.beginInterval("Send", id: Signposts.poi.makeSignpostID())
        if let edit = editTarget {
            editTarget = nil
            compose.clearAfterSend()
            Task {
                do { try await client.edit(edit.message.key, text: text) } catch { Signposts.log.error("edit failed: \(error)") }
                Signposts.poi.endInterval("Send", state, "edit")
            }
        } else if !staged.isEmpty {
            let items = staged
            let reply = replyTarget
            staged = []
            replyTarget = nil
            refreshTray()
            compose.clearAfterSend()
            let client = self.client
            Task {
                // Waits for any metadata still being computed; items that failed to prepare are skipped.
                var prepared: [PreparedAttachment] = []
                for item in items {
                    if let p = try? await item.task.value { prepared.append(p) }
                }
                do { try await client.sendAttachments(prepared, caption: text, to: chatJid, replyTo: reply) }
                catch { Signposts.log.error("media send failed: \(error)") }
                Signposts.poi.endInterval("Send", state, "media")
            }
        } else {
            let reply = replyTarget
            replyTarget = nil
            compose.clearAfterSend()
            Task {
                do { try await client.sendText(text, to: chatJid, replyTo: reply) } catch { Signposts.log.error("send failed: \(error)") }
                Signposts.poi.endInterval("Send", state, "text")
            }
        }
        drafts[chatJid] = nil
        sendPaused()
    }

    private func editLastOwnMessage() {
        guard let item = list.rows.lastOwnEditable else { return }
        edit(item)
    }

    // MARK: - Typing state

    private func noteTyping() {
        guard let chatJid, !compose.textView.isEmpty else { return }
        let now = Date()
        if now.timeIntervalSince(lastComposingSent) > 4 {
            lastComposingSent = now
            Task { await client.sendChatState(.composing, in: chatJid) }
        }
        pausedTimer?.invalidate()
        pausedTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendPaused() }
        }
    }

    private func sendPaused() {
        pausedTimer?.invalidate()
        pausedTimer = nil
        guard lastComposingSent != .distantPast, let chatJid else { return }
        lastComposingSent = .distantPast
        Task { await client.sendChatState(.paused, in: chatJid) }
    }

    // MARK: - Quick Look forwarding (when compose is first responder)

    public override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        list.acceptsPreviewPanelControl(panel)
    }

    public override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        list.beginPreviewPanelControl(panel)
    }

    public override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        list.endPreviewPanelControl(panel)
    }
}

// MARK: - List actions

extension ChatViewController: MessageListActions {
    func reply(to item: MessageItem) {
        editTarget = nil
        replyTarget = item
        let name: String
        if item.message.fromMe { name = "You" }
        else if list.rows.isGroupChat { name = item.senderName ?? peerDisplayName() }
        else { name = list.chatName ?? item.senderName ?? peerDisplayName() }
        let snippet = item.message.text.flatMap { $0.isEmpty ? nil : $0 } ?? kindLabel(item.message.kind)
        compose.setBar(.reply(name: name, snippet: snippet.replacingOccurrences(of: "\n", with: " "),
                              color: item.message.fromMe ? .controlAccentColor : MessageTextConfiguration.senderColor(for: item.message.senderJid)))
        compose.focus()
    }

    private func peerDisplayName() -> String {
        chatJid.map { LayoutPlanner.phoneDisplay($0) } ?? ""
    }

    private func kindLabel(_ kind: MessageKind) -> String {
        switch kind {
        case .image: "Photo"
        case .video: "Video"
        case .gif: "GIF"
        case .sticker: "Sticker"
        case .document: "Document"
        case .audio: "Audio"
        case .voice: "Voice message"
        case .location: "Location"
        case .contact: "Contact"
        case .poll: "Poll"
        default: "Message"
        }
    }

    func toggleReaction(_ emoji: String, on item: MessageItem) {
        let mine = item.reactions.first { $0.fromMe }
        let next = mine?.emoji == emoji ? "" : emoji
        Task {
            do { try await client.react(to: item.message.key, emoji: next) } catch { Signposts.log.error("react failed: \(error)") }
        }
    }

    func edit(_ item: MessageItem) {
        guard item.message.fromMe, item.message.kind == .text, let original = item.message.text else { return }
        replyTarget = nil
        editTarget = item
        compose.setBar(.edit(original: original))
        compose.text = original
        compose.focus()
    }

    func revoke(_ item: MessageItem) {
        let alert = NSAlert()
        alert.messageText = "Delete this message for everyone?"
        alert.informativeText = "It will be removed for all participants in this chat."
        alert.addButton(withTitle: "Delete for Everyone")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task {
                do { try await self.client.revoke(item.message.key) } catch { Signposts.log.error("revoke failed: \(error)") }
            }
        }
    }

    func retry(_ item: MessageItem) {
        Task {
            do { try await client.retry(localId: item.id, chatJid: item.message.chatJid) } catch { Signposts.log.error("retry failed: \(error)") }
        }
    }

    func typeToCompose(_ text: String) {
        insertComposeText(text)
    }

    func escapeFromList() {
        if !handleEscape() { onEscapeWithNothingToClear?() }
    }
}
