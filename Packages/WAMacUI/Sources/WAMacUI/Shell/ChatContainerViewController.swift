import AppKit
import SwiftUI
import WAKit

/// Content side of the split view: hosts the single `ChatViewController`, or an empty state when no
/// chat is selected. `beginComposing(with:)` receives text typed while the chat list had focus.
@MainActor
public final class ChatContainerViewController: NSViewController {
    public let client: WAClient
    public let chatView: ChatViewController
    public private(set) var chatJid: String?

    /// Second Esc with nothing to clear in compose; the shell focuses the chat list.
    public var onEscapeToChatList: (() -> Void)? {
        get { chatView.onEscapeWithNothingToClear }
        set { chatView.onEscapeWithNothingToClear = newValue }
    }

    /// Debug override for the shortcut self-test; when set, type-ahead text goes here instead of compose.
    public var composeTextSink: ((String) -> Void)?

    private let emptyState = NSHostingView(rootView: EmptyChatView())
    /// The open chat's avatar and name at the top center of the thread (iMessage style), as a
    /// soft-edged top accessory of the split view item: messages scroll under it and fade out.
    let header = ChatHeaderModel()
    private(set) lazy var headerAccessory: SoftEdgeAccessory = {
        let accessory = SoftEdgeAccessory(content: ChatHeaderView(model: header), horizontalInset: 16)
        accessory.isHidden = true
        return accessory
    }()

    public init(client: WAClient) {
        self.client = client
        chatView = ChatViewController(client: client)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = ShellRootView()
        root.wantsLayer = true
        addChild(chatView)
        emptyState.sizingOptions = []
        for sub in [chatView.view, emptyState] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
            NSLayoutConstraint.activate([
                sub.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                sub.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                sub.topAnchor.constraint(equalTo: root.topAnchor),
                sub.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        chatView.view.isHidden = true
        view = root
    }

    /// Shows `chatJid`, or the empty state for `nil`.
    public func show(chatJid: String?) {
        self.chatJid = chatJid
        chatView.show(chatJid: chatJid)
        chatView.view.isHidden = chatJid == nil
        headerAccessory.isHidden = chatJid == nil
        emptyState.isHidden = chatJid != nil
    }

    /// Warms layout for a chat the user is likely to open next (hover, keyboard focus).
    public func prewarm(chatJid: String) {
        ChatOpenPreloader.shared.warm(chatJid: chatJid, width: chatView.view.bounds.width, client: client)
    }

    /// Forwarded from the chat list when the user starts typing while it has focus.
    public func beginComposing(with text: String) {
        if let composeTextSink { return composeTextSink(text) }
        guard chatJid != nil else { return }
        chatView.insertComposeText(text)
        chatView.focusCompose()
    }

    // Keyboard seam for the shell's menu shortcuts (Esc, ⇧⌘O, Space, command-bar focus).

    /// Esc. Returns true when the chat view consumed it (cleared reply/edit state).
    public func cancelTransientState() -> Bool { chatJid != nil && chatView.handleEscape() }
    /// Menu title for Esc while there is something to cancel ("Cancel Reply"), else nil.
    public var transientStateTitle: String? { chatJid == nil ? nil : chatView.transientStateTitle }
    public var canAttach: Bool { chatJid != nil }
    public func attachFile() { chatView.attachFile() }
    public var canQuickLook: Bool { chatJid != nil && chatView.canQuickLookSelection }
    public func quickLook() { chatView.quickLookSelection() }
    /// After the command bar opens a chat. Returns false when there is no chat to compose in.
    public func focusCompose() -> Bool {
        guard chatJid != nil else { return false }
        chatView.focusCompose()
        return true
    }
}

private struct EmptyChatView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No Chat Selected")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Choose a conversation, or press ⌘K to search.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
