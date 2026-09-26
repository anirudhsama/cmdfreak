import AppKit

/// Read-only TextKit 2 text view for message bodies: selection and link clicks, no editing, and a
/// zero-padding container so the rendered size equals `TextMeasurer`'s.
final class MessageTextView: NSTextView {
    static func make() -> MessageTextView {
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        let layoutManager = NSTextLayoutManager()
        layoutManager.textContainer = container
        let storage = NSTextContentStorage()
        storage.addTextLayoutManager(layoutManager)
        let view = MessageTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticLinkDetectionEnabled = false
        view.displaysLinkToolTips = true
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        view.setAccessibilityRole(.staticText)
        return view
    }

    func setContent(_ text: NSAttributedString, size: CGSize) {
        textContainer?.size = CGSize(width: size.width, height: size.height + 4)
        textStorage?.setAttributedString(text)
        frame.size = size
    }

    /// Right-clicks belong to the row (message context menu), not the text view's edit menu.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) {
        superview?.rightMouseDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }

    /// Keep the arrow keys and Space for the list.
    override func keyDown(with event: NSEvent) {
        nextResponder?.keyDown(with: event)
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        if let url = link as? URL { NSWorkspace.shared.open(url) }
        else if let s = link as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
