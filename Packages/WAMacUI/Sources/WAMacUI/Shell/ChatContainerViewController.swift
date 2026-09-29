import AppKit
import SwiftUI
import WAKit

/// Content side of the split view: hosts the single `ChatViewController`, or an empty state when no
/// chat is selected.
@MainActor
public final class ChatContainerViewController: NSViewController {
    public let client: WAClient
    public let chatView: ChatViewController
    public private(set) var chatJid: String?

    private let emptyState = NSHostingView(rootView: EmptyChatView())
    /// The open chat's avatar, name and subtitle in the toolbar strip over the conversation,
    /// aligned with the message bubbles' leading edge.
    let header = ChatHeaderModel()
    private lazy var headerView = ChatHeaderView(model: header)
    private var typingObservation: ObservationToken?

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

        // The toolbar strip: from the top of the view to the safe area.
        let band = NSLayoutGuide()
        root.addLayoutGuide(band)
        headerView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerView)
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: root.topAnchor),
            band.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            headerView.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            headerView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: MessageTextConfiguration.Metrics.horizontalInset),
            headerView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])
        headerView.isHidden = true
        view = root

        // The header follows the open chat's row state; the typing bubble follows the same state.
        typingObservation = WAMacUI.observe { [weak self] in
            guard let self else { return }
            chatView.setTyping(header.state?.typing)
        }
    }

    /// Shows `chatJid`, or the empty state for `nil`.
    public func show(chatJid: String?) {
        self.chatJid = chatJid
        chatView.show(chatJid: chatJid)
        chatView.view.isHidden = chatJid == nil
        headerView.isHidden = chatJid == nil
        emptyState.isHidden = chatJid != nil
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
    /// After a chat switch or a search hand-off. Returns false when there is no chat to compose in.
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
