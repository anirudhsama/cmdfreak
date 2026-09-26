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

    private let emptyState = NSHostingView(rootView: EmptyChatView())

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
        emptyState.isHidden = chatJid != nil
    }

    /// Warms layout for a chat the user is likely to open next (hover, keyboard focus).
    public func prewarm(chatJid: String) {
        ChatOpenPreloader.shared.warm(chatJid: chatJid, width: chatView.view.bounds.width, client: client)
    }

    /// Forwarded from the chat list when the user starts typing while it has focus.
    public func beginComposing(with text: String) {
        guard chatJid != nil else { return }
        chatView.insertComposeText(text)
        chatView.focusCompose()
    }

    @objc public func attachFile(_ sender: Any?) { chatView.attachFile() }
    @objc public func quickLookSelection(_ sender: Any?) { chatView.quickLookSelection() }
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
