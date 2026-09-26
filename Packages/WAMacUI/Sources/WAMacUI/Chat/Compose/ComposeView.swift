import AppKit

/// Liquid-glass compose pill: reply/edit bar, attachment tray, TextKit 2 editor, send button.
/// With attachments staged, the editor text is their caption and Enter sends even when it's empty.
/// Enter sends, ⇧Enter inserts a newline, ↑ in an empty editor asks to edit the last message,
/// Esc clears the bar first and then escalates to `onEscape`.
final class ComposeView: NSView, NSTextViewDelegate {
    enum Bar: Equatable {
        case reply(name: String, snippet: String, color: NSColor)
        case edit(original: String)
    }

    var onSend: ((String) -> Void)?
    var onTyping: (() -> Void)?
    var onEscape: (() -> Void)?
    var onArrowUpEmpty: (() -> Void)?
    var onAttach: (() -> Void)?
    var onPasteFiles: (([URL]) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    var onCancelBar: (() -> Void)?
    var onRemoveAttachment: ((UUID) -> Void)?

    private(set) var bar: Bar?

    let textView = ComposeTextView.make()
    private let container = NSGlassEffectContainerView()
    private let pill = NSGlassEffectView()
    private let content = NSView()
    private let scroll = NSScrollView()
    private let attachButton = NSButton()
    private let sendButton = NSButton()
    private let barView = NSView()
    private let barAccent = NSView()
    private let barTitle = NSTextField(labelWithString: "")
    private let barSnippet = NSTextField(labelWithString: "")
    private let barClose = NSButton()
    private let tray = AttachmentTrayView()
    private var trayHeight: NSLayoutConstraint!
    private(set) var hasAttachments = false
    private var textHeight: NSLayoutConstraint!
    private var barHeight: NSLayoutConstraint!

    static let outerInsets = NSEdgeInsets(top: 6, left: 12, bottom: 10, right: 12)
    static let maxLines = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        container.contentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pill)
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.cornerRadius = 20
        pill.style = .regular
        let pillContent = NSView()
        pillContent.translatesAutoresizingMaskIntoConstraints = false
        pill.contentView = pillContent

        // Reply / edit bar
        barView.translatesAutoresizingMaskIntoConstraints = false
        barView.wantsLayer = true
        barView.layer?.cornerRadius = 10
        barView.layer?.backgroundColor = MessageTextConfiguration.quoteBackground.cgColor
        barAccent.translatesAutoresizingMaskIntoConstraints = false
        barAccent.wantsLayer = true
        barTitle.font = MessageTextConfiguration.quoteName
        barTitle.lineBreakMode = .byTruncatingTail
        barSnippet.font = MessageTextConfiguration.quoteBody
        barSnippet.textColor = .secondaryLabelColor
        barSnippet.lineBreakMode = .byTruncatingTail
        barTitle.translatesAutoresizingMaskIntoConstraints = false
        barSnippet.translatesAutoresizingMaskIntoConstraints = false
        barClose.translatesAutoresizingMaskIntoConstraints = false
        barClose.bezelStyle = .accessoryBarAction
        barClose.isBordered = false
        barClose.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")
        barClose.contentTintColor = .secondaryLabelColor
        barClose.target = self
        barClose.action = #selector(cancelBar)
        barView.addSubview(barAccent)
        barView.addSubview(barTitle)
        barView.addSubview(barSnippet)
        barView.addSubview(barClose)
        barView.isHidden = true
        pillContent.addSubview(barView)

        tray.translatesAutoresizingMaskIntoConstraints = false
        tray.isHidden = true
        tray.onRemove = { [weak self] id in self?.onRemoveAttachment?(id) }
        pillContent.addSubview(tray)

        // Attach
        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.bezelStyle = .accessoryBarAction
        attachButton.isBordered = false
        attachButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Attach")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        attachButton.contentTintColor = .secondaryLabelColor
        attachButton.target = self
        attachButton.action = #selector(attachTapped)
        attachButton.toolTip = "Attach file"
        pillContent.addSubview(attachButton)

        // Editor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = textView
        scroll.verticalScrollElasticity = .none
        textView.delegate = self
        textView.onPasteFiles = { [weak self] urls in self?.onPasteFiles?(urls) }
        pillContent.addSubview(scroll)

        // Send
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.bezelStyle = .accessoryBarAction
        sendButton.isBordered = false
        sendButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        sendButton.contentTintColor = .controlAccentColor
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.isEnabled = false
        pillContent.addSubview(sendButton)

        textHeight = scroll.heightAnchor.constraint(equalToConstant: 30)
        barHeight = barView.heightAnchor.constraint(equalToConstant: 0)
        trayHeight = tray.heightAnchor.constraint(equalToConstant: 0)
        let o = Self.outerInsets
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: o.left),
            container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -o.right),
            container.topAnchor.constraint(equalTo: topAnchor, constant: o.top),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -o.bottom),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pill.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pill.topAnchor.constraint(equalTo: content.topAnchor),
            pill.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            pillContent.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            pillContent.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            pillContent.topAnchor.constraint(equalTo: pill.topAnchor),
            pillContent.bottomAnchor.constraint(equalTo: pill.bottomAnchor),

            barView.leadingAnchor.constraint(equalTo: pillContent.leadingAnchor, constant: 8),
            barView.trailingAnchor.constraint(equalTo: pillContent.trailingAnchor, constant: -8),
            barView.topAnchor.constraint(equalTo: pillContent.topAnchor, constant: 8),
            barHeight,
            barAccent.leadingAnchor.constraint(equalTo: barView.leadingAnchor),
            barAccent.topAnchor.constraint(equalTo: barView.topAnchor),
            barAccent.bottomAnchor.constraint(equalTo: barView.bottomAnchor),
            barAccent.widthAnchor.constraint(equalToConstant: 3),
            barTitle.leadingAnchor.constraint(equalTo: barView.leadingAnchor, constant: 12),
            barTitle.topAnchor.constraint(equalTo: barView.topAnchor, constant: 5),
            barTitle.trailingAnchor.constraint(equalTo: barClose.leadingAnchor, constant: -8),
            barSnippet.leadingAnchor.constraint(equalTo: barTitle.leadingAnchor),
            barSnippet.topAnchor.constraint(equalTo: barTitle.bottomAnchor, constant: 1),
            barSnippet.trailingAnchor.constraint(equalTo: barTitle.trailingAnchor),
            barClose.trailingAnchor.constraint(equalTo: barView.trailingAnchor, constant: -6),
            barClose.centerYAnchor.constraint(equalTo: barView.centerYAnchor),
            barClose.widthAnchor.constraint(equalToConstant: 22),
            barClose.heightAnchor.constraint(equalToConstant: 22),

            attachButton.leadingAnchor.constraint(equalTo: pillContent.leadingAnchor, constant: 8),
            attachButton.bottomAnchor.constraint(equalTo: pillContent.bottomAnchor, constant: -6),
            attachButton.widthAnchor.constraint(equalToConstant: 28),
            attachButton.heightAnchor.constraint(equalToConstant: 28),
            scroll.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -4),
            tray.leadingAnchor.constraint(equalTo: pillContent.leadingAnchor, constant: 10),
            tray.trailingAnchor.constraint(equalTo: pillContent.trailingAnchor, constant: -10),
            tray.topAnchor.constraint(equalTo: barView.bottomAnchor),
            trayHeight,
            scroll.topAnchor.constraint(equalTo: tray.bottomAnchor, constant: 5),
            scroll.bottomAnchor.constraint(equalTo: pillContent.bottomAnchor, constant: -5),
            textHeight,
            sendButton.trailingAnchor.constraint(equalTo: pillContent.trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: pillContent.bottomAnchor, constant: -6),
            sendButton.widthAnchor.constraint(equalToConstant: 28),
            sendButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        updateHeight()
    }

    // MARK: - Public

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            textView.setSelectedRange(NSRange(location: (newValue as NSString).length, length: 0))
            textDidChange(Notification(name: NSText.didChangeNotification))
        }
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func insert(_ s: String) {
        focus()
        textView.insertText(s, replacementRange: textView.selectedRange())
    }

    func setBar(_ bar: Bar?) {
        self.bar = bar
        switch bar {
        case .reply(let name, let snippet, let color):
            barTitle.stringValue = name
            barTitle.textColor = color
            barSnippet.stringValue = snippet
            barAccent.layer?.backgroundColor = color.cgColor
        case .edit:
            barTitle.stringValue = "Edit message"
            barTitle.textColor = .controlAccentColor
            barSnippet.stringValue = "Enter to save · Esc to cancel"
            barAccent.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        case nil:
            break
        }
        barView.isHidden = bar == nil
        barHeight.constant = bar == nil ? 0 : 40
        updateHeight()
    }

    func setAttachments(_ items: [AttachmentTrayView.Item]) {
        hasAttachments = !items.isEmpty
        tray.set(items)
        tray.isHidden = items.isEmpty
        trayHeight.constant = items.isEmpty ? 0 : AttachmentTrayView.height
        textView.placeholder = items.isEmpty ? "Message" : "Add a caption…"
        textView.needsDisplay = true
        updateSendEnabled()
        updateHeight()
    }

    /// Esc: clears the bar (and edit text) first; returns false when there was nothing to clear.
    @discardableResult
    func handleEscape() -> Bool {
        guard bar != nil else { return false }
        if case .edit = bar { text = "" }
        setBar(nil)
        onCancelBar?()
        return true
    }

    // MARK: - Actions

    @objc private func sendTapped() { send() }
    @objc private func attachTapped() { onAttach?() }
    @objc private func cancelBar() { handleEscape() }

    private func send() {
        let t = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || hasAttachments else { return }
        onSend?(t)
    }

    /// Called by the owner after a successful send/edit hand-off.
    func clearAfterSend() {
        textView.string = ""
        textView.undoManager?.removeAllActions()
        setBar(nil)
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        updateSendEnabled()
        updateHeight()
        onTyping?()
    }

    private func updateSendEnabled() {
        sendButton.isEnabled = !textView.isEmpty || hasAttachments
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            send()
            return true
        case #selector(NSResponder.moveUp(_:)):
            if textView.string.isEmpty, bar == nil {
                onArrowUpEmpty?()
                return true
            }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            if !handleEscape() { onEscape?() }
            return true
        default:
            return false
        }
    }

    private func updateHeight() {
        let h = textView.contentHeight(maxLines: Self.maxLines)
        if abs(textHeight.constant - h) > 0.5 {
            textHeight.constant = h
        }
        let total = Self.outerInsets.top + Self.outerInsets.bottom + 10 + h + barHeight.constant + (bar == nil ? 0 : 5) + trayHeight.constant
        onHeightChange?(ceil(total))
    }
}
