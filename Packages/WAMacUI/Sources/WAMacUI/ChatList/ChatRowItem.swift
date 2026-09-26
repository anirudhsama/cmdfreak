import AppKit
import SwiftUI

/// Reusable collection item. Creates its `NSHostingView` once; `configure` only swaps the state
/// object the hosted row reads, so scrolling never rebuilds a SwiftUI tree.
@MainActor
final class ChatRowItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ChatRowItem")

    private var hostingView: NSHostingView<ChatRowView>?
    private(set) var state: ChatRowState?
    var onContextMenu: ((ChatRowState) -> NSMenu?)?

    override func loadView() {
        let root = ChatRowRootView()
        root.wantsLayer = true
        root.onContextMenu = { [weak self] in
            guard let self, let state else { return nil }
            return onContextMenu?(state)
        }
        view = root
    }

    func configure(state: ChatRowState, appearance: ChatListAppearance) {
        if let previous = self.state, previous !== state { previous.isSelected = false }
        self.state = state
        state.isSelected = isSelected
        if let hostingView {
            hostingView.rootView = ChatRowView(state: state, appearance: appearance)
        } else {
            let hostingView = NSHostingView(rootView: ChatRowView(state: state, appearance: appearance))
            hostingView.sizingOptions = []
            hostingView.frame = view.bounds
            hostingView.autoresizingMask = [.width, .height]
            view.addSubview(hostingView)
            self.hostingView = hostingView
        }
    }

    override var isSelected: Bool {
        didSet { state?.isSelected = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        state?.isSelected = false
        state = nil
    }
}

/// Item root: routes right-clicks to a menu without stealing left-click selection from the collection view.
final class ChatRowRootView: NSView {
    var onContextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?()
    }
}
