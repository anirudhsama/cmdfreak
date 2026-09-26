import AppKit
import SwiftUI
import WAKit

/// Keyboard seam between the shell's menu shortcuts and the chat view. The chat view adopts this
/// and sets itself as `ChatContainerViewController.content`; every member has a no-op default.
@MainActor
public protocol ChatContentKeyboardHandling: AnyObject {
    /// Esc: clear reply or edit state. Return false when there was nothing to clear, so the shell
    /// moves focus to the chat list instead.
    func cancelTransientState() -> Bool
    /// Menu title for Esc while there is something to cancel ("Cancel Reply"), else nil.
    var transientStateTitle: String? { get }
    /// ⇧⌘O.
    func attachFile()
    /// Space with the message list focused: whether a media message is selected.
    var canQuickLookSelection: Bool { get }
    func quickLookSelection()
    /// After the command bar opens a chat. Return false to leave focus on the chat list.
    func focusCompose() -> Bool
}

public extension ChatContentKeyboardHandling {
    func cancelTransientState() -> Bool { false }
    var transientStateTitle: String? { nil }
    func attachFile() {}
    var canQuickLookSelection: Bool { false }
    func quickLookSelection() {}
    func focusCompose() -> Bool { false }
}

/// Content side of the split view. Owns the seam the chat view plugs into: `show(chatJid:)` swaps
/// the displayed conversation; `beginComposing(with:)` receives text typed while the chat list
/// had focus. Until the real chat view lands it shows an empty state.
@MainActor
public final class ChatContainerViewController: NSViewController {
    public let client: WAClient
    public private(set) var chatJid: String?

    /// Set by the chat view once it exists; receives printable characters typed in the chat list.
    public var composeTextSink: ((String) -> Void)?
    /// Set by the chat view once it exists; receives Esc, ⇧⌘O, Space and focus requests from the shell.
    public weak var content: (any ChatContentKeyboardHandling)?

    private let emptyState = NSHostingView(rootView: EmptyChatView())

    public init(client: WAClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = ShellRootView()
        root.wantsLayer = true
        emptyState.sizingOptions = []
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: root.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// Shows `chatJid`, or the empty state for `nil`. The real chat view replaces the body of this method.
    public func show(chatJid: String?) {
        self.chatJid = chatJid
        emptyState.rootView = EmptyChatView(chatJid: chatJid)
    }

    /// Esc. Returns true when the chat view consumed it (cleared reply/edit state).
    public func cancelTransientState() -> Bool { content?.cancelTransientState() ?? false }
    public var transientStateTitle: String? { content?.transientStateTitle }
    public var canAttach: Bool { chatJid != nil && content != nil }
    public func attachFile() { content?.attachFile() }
    public var canQuickLook: Bool { content?.canQuickLookSelection ?? false }
    public func quickLook() { content?.quickLookSelection() }
    public func focusCompose() -> Bool { content?.focusCompose() ?? false }

    /// Forwarded from the chat list when the user starts typing while it has focus.
    public func beginComposing(with text: String) {
        composeTextSink?(text)
    }
}

private struct EmptyChatView: View {
    var chatJid: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: chatJid == nil ? "bubble.left.and.bubble.right" : "bubble.left.and.text.bubble.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(chatJid == nil ? "No Chat Selected" : "Chat view coming soon")
                .font(.title3)
                .foregroundStyle(.secondary)
            if chatJid == nil {
                Text("Choose a conversation, or press ⌘K to search.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
