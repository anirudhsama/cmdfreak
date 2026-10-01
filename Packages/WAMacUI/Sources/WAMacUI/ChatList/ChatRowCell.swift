import AppKit
import SwiftUI

/// Reusable table cell. Creates its `NSHostingView` once; `configure` only swaps the state object
/// the hosted row reads, so scrolling never rebuilds a SwiftUI tree.
@MainActor
final class ChatRowCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("ChatRowCell")

    private var hostingView: ChatRowHostingView?
    private(set) var state: ChatRowState?
    var onContextMenu: ((ChatRowState) -> NSMenu?)?
    /// Buttons a swipe uncovers, outermost first.
    private var swipeButtons: [SwipeActionButton] = []

    func configure(state: ChatRowState, appearance: ChatListAppearance) {
        // A cell only comes back here once out of the list, so any swipe it shows is stale.
        resetSwipe(animated: false)
        self.state = state
        if let hostingView {
            hostingView.rootView = ChatRowView(state: state, appearance: appearance)
        } else {
            let hostingView = ChatRowHostingView(rootView: ChatRowView(state: state, appearance: appearance))
            hostingView.sizingOptions = []
            hostingView.frame = bounds
            hostingView.autoresizingMask = [.width, .height]
            addSubview(hostingView)
            self.hostingView = hostingView
            // The row slides past the cell's edges during a swipe.
            clipsToBounds = true
        }
    }

    // MARK: Swipe

    /// Shows `actions` (outermost first) in the space a swipe uncovers; `onPress` gets the index.
    func setSwipeActions(_ actions: [SwipeAction], onPress: @escaping (Int) -> Void) {
        while swipeButtons.count < actions.count {
            let button = SwipeActionButton()
            addSubview(button, positioned: .below, relativeTo: hostingView)
            swipeButtons.append(button)
        }
        while swipeButtons.count > actions.count { swipeButtons.removeLast().removeFromSuperview() }
        for (index, (button, action)) in zip(swipeButtons, actions).enumerated() {
            button.configure(action)
            button.onPress = { onPress(index) }
        }
    }

    /// Moves the row `offset` points (positive uncovers the leading edge) and lays out the buttons
    /// in the space it leaves. `armed` (0 to 1) is how far a full swipe has armed.
    func setSwipe(offset: CGFloat, armed: CGFloat) {
        hostingView?.frame.origin.x = offset
        let leading = offset > 0
        let layouts = SwipeButtonLayout.layouts(revealed: abs(offset), count: swipeButtons.count, armed: armed)
        for (index, (button, layout)) in zip(swipeButtons, layouts).enumerated() {
            let x = leading ? layout.inset : bounds.width - layout.inset - layout.length
            button.frame = NSRect(x: x, y: (bounds.height - layout.diameter) / 2, width: layout.length, height: layout.diameter)
            button.isHidden = layout.diameter < 1
            button.layout(opacity: layout.opacity, iconShift: index == 0 ? armed : 0, rowSideIsMaxX: leading)
        }
    }

    func resetSwipe(animated: Bool) {
        guard let hostingView, hostingView.frame.origin.x != 0 || !swipeButtons.isEmpty else { return }
        let buttons = swipeButtons
        swipeButtons = []
        guard animated else {
            hostingView.frame.origin.x = 0
            buttons.forEach { $0.removeFromSuperview() }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hostingView.animator().frame.origin.x = 0
            buttons.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: {
            MainActor.assumeIsolated { buttons.forEach { $0.removeFromSuperview() } }
        }
    }

    /// Routes right-clicks to a menu without stealing left-click selection from the table view.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let state else { return nil }
        return onContextMenu?(state)
    }
}

/// Mirrors the table's selection into the row's state; the SwiftUI row draws the highlight itself.
@MainActor
final class ChatTableRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ChatTableRowView")

    var state: ChatRowState? {
        didSet {
            if let oldValue, oldValue !== state { oldValue.isSelected = false }
            state?.isSelected = isSelected
        }
    }

    override var isSelected: Bool {
        didSet { state?.isSelected = isSelected }
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

private final class ChatRowHostingView: NSHostingView<ChatRowView> {
    #if DEBUG
    /// Self-test only: a click in a window that is not key (a locked test session) would only bring it forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { MainWindowController.debugAssumeKeyWindow }
    #endif
}
