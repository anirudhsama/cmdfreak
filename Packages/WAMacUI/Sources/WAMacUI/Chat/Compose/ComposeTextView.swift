import AppKit

/// TextKit 2 editor for the compose pill. Key semantics live in the delegate's `doCommandBy`.
final class ComposeTextView: NSTextView {
    var placeholder = "Message"

    static func make() -> ComposeTextView {
        let view = ComposeTextView(usingTextLayoutManager: true)
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = MessageTextConfiguration.body
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 0, height: 6)
        view.textContainer?.lineFragmentPadding = 2
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = true
        view.isAutomaticSpellingCorrectionEnabled = true
        view.isContinuousSpellCheckingEnabled = true
        view.isAutomaticLinkDetectionEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("Message")
        return view
    }

    var isEmpty: Bool { string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Rendered height for the current text, clamped to `maxLines`.
    func contentHeight(maxLines: Int) -> CGFloat {
        guard let lm = textLayoutManager, let container = textContainer else { return 30 }
        lm.ensureLayout(for: lm.documentRange)
        let used = lm.usageBoundsForTextContainer.height
        let lineH = ceil((font ?? MessageTextConfiguration.body).ascender - (font ?? MessageTextConfiguration.body).descender + (font ?? MessageTextConfiguration.body).leading) + 1
        _ = container
        let content = max(lineH, ceil(used))
        return min(content, lineH * CGFloat(maxLines)) + textContainerInset.height * 2
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? MessageTextConfiguration.body, .foregroundColor: NSColor.placeholderTextColor]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        NSAttributedString(string: placeholder, attributes: attrs).draw(at: origin)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    // Programmatic assignments (edit prefill, draft restore, clear after send) skip didChangeText;
    // TextKit 2 draws the text in its own layers, so a stale placeholder would show through.
    override var string: String {
        didSet { needsDisplay = true }
    }

    /// Pasted or dropped files and images become attachments; text pastes through as plain text.
    var onPasteFiles: (([URL]) -> Void)?
    /// ⌘R while editing.
    var onReplyShortcut: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let onReplyShortcut, window?.firstResponder === self,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "r" {
            onReplyShortcut()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        if let onPasteFiles {
            let urls = PasteboardAttachments.urls(from: .general)
            if !urls.isEmpty {
                onPasteFiles(urls)
                return
            }
        }
        pasteAsPlainText(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), onPasteFiles != nil, PasteboardAttachments.canRead(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    // Files dropped on the editor attach instead of inserting their paths.
    private func isAttachmentDrag(_ info: any NSDraggingInfo) -> Bool {
        onPasteFiles != nil && info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isAttachmentDrag(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isAttachmentDrag(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isAttachmentDrag(sender) else { return super.performDragOperation(sender) }
        let urls = PasteboardAttachments.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onPasteFiles?(urls)
        return true
    }
}
