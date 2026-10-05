import AppKit
import WAKit

/// Read-only TextKit 2 text view for message bodies: selection and link clicks, no editing, and a
/// zero-padding container so the rendered size equals `TextMeasurer`'s. A click on a mention opens a menu
/// to message that person.
final class MessageTextView: NSTextView, NSTextViewDelegate {
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
        view.linkTextAttributes = [.foregroundColor: MarkdownLite.linkColor, .cursor: NSCursor.pointingHand]
        view.setAccessibilityRole(.staticText)
        view.delegate = view
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
        var range = NSRange()
        if let storage = textStorage,
           let mention = storage.attribute(.mention, at: charIndex, longestEffectiveRange: &range,
                                           in: NSRange(location: 0, length: storage.length)) as? Mention {
            showMenu(for: mention, range: range)
            return
        }
        if let url = link as? URL { NSWorkspace.shared.open(url) }
        else if let s = link as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    /// Mention links carry an internal URL; show no tooltip for them.
    func textView(_ textView: NSTextView, willDisplayToolTip tooltip: String, forCharacterAt characterIndex: Int) -> String? {
        textStorage?.attribute(.mention, at: characterIndex, effectiveRange: nil) == nil ? tooltip : nil
    }

    /// Drops down from the mention. "Message" goes up the responder chain to `MainWindowController`.
    private func showMenu(for mention: Mention, range: NSRange) {
        guard let jid = mention.jid else { return }
        let menu = NSMenu()
        let message = menu.addItem(withTitle: "Message \(mention.name)",
                                   action: #selector(MainWindowController.messageMention(_:)), keyEquivalent: "")
        message.representedObject = jid
        if let phone = mention.phone {
            let copy = menu.addItem(withTitle: "Copy Phone Number", action: #selector(copyMentionPhone(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = phone.filter { $0 == "+" || $0.isNumber }
        }
        var anchor = NSPoint(x: 0, y: bounds.maxY)
        let screenRect = firstRect(forCharacterRange: range, actualRange: nil)
        if let window, screenRect != .zero {
            let r = convert(window.convertFromScreen(screenRect), from: nil)
            anchor = NSPoint(x: r.minX, y: r.maxY + 2)
        }
        menu.popUp(positioning: nil, at: anchor, in: self)
    }

    @objc private func copyMentionPhone(_ sender: NSMenuItem) {
        guard let phone = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(phone, forType: .string)
    }
}
