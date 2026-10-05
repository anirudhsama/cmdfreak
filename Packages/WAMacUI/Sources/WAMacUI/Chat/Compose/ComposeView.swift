import AppKit
import WAKit

/// Liquid-glass compose pill: reply/edit bar, attachment tray, TextKit 2 editor, send button.
/// With attachments staged, the editor text is their caption and Enter sends even when it's empty.
/// Enter sends, ⇧Enter inserts a newline, ↑ in an empty editor moves into the message list, ⌘R
/// replies to the newest incoming message, Esc clears the bar first and then escalates to `onEscape`.
///
/// Mentions are "@<name>" runs carrying `.composeMention`; they go out as "@<number>" (see `composed`).
/// While `mentionsEnabled`, an "@" starting a word reports the name typed after it to `onMentionQuery`,
/// and `onMentionKey` gets first refusal of ↑, ↓, Enter, Tab and Esc.
final class ComposeView: NSView, NSTextViewDelegate {
    enum Bar: Equatable {
        case reply(name: String, snippet: NSAttributedString, color: NSColor)
        case edit(original: String)
    }

    enum MentionKey { case up, down, accept, dismiss }

    var onSend: ((ComposedText) -> Void)?
    var onMentionQuery: ((String?) -> Void)?
    /// Returns true when the mention picker handled the key.
    var onMentionKey: ((MentionKey) -> Bool)?
    var mentionsEnabled = false {
        didSet { if !mentionsEnabled { reportMentionQuery() } }
    }
    var onTyping: (() -> Void)?
    var onEscape: (() -> Void)?
    var onArrowUpEmpty: (() -> Void)?
    var onReplyShortcut: (() -> Void)? {
        get { textView.onReplyShortcut }
        set { textView.onReplyShortcut = newValue }
    }
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
    private var barTop: NSLayoutConstraint!

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
        // A long quote must truncate, not widen the chat column and squeeze the split view's list.
        for label in [barTitle, barSnippet] {
            label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        }
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
        textView.willSetMarkedText = { [weak self] in self?.plainMentions(touching: $0) }
        textView.onPasteFiles = { [weak self] urls in self?.onPasteFiles?(urls) }
        pillContent.addSubview(scroll)

        // Send
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.bezelStyle = .accessoryBarAction
        sendButton.isBordered = false
        sendButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        sendButton.contentTintColor = Palette.green
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.isEnabled = false
        pillContent.addSubview(sendButton)

        textHeight = scroll.heightAnchor.constraint(equalToConstant: 30)
        barHeight = barView.heightAnchor.constraint(equalToConstant: 0)
        barTop = barView.topAnchor.constraint(equalTo: pillContent.topAnchor)
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
            barTop,
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

    /// Programmatic (draft restore, edit prefill): does not count as typing, so no `composing` presence.
    var text: String {
        get { textView.string }
        set { draft = NSAttributedString(string: newValue) }
    }

    /// The editor's text with its mention runs, for drafts. Setting it is programmatic, like `text`.
    var draft: NSAttributedString {
        get { NSAttributedString(attributedString: textView.textStorage ?? NSTextStorage()) }
        set {
            let styled = NSMutableAttributedString(string: newValue.string, attributes: Self.plainAttributes)
            newValue.enumerateAttribute(.composeMention, in: NSRange(location: 0, length: newValue.length)) { value, range, _ in
                if let mention = value as? ComposeMention { styled.addAttributes(Self.mentionAttributes(mention), range: range) }
            }
            textView.textStorage?.setAttributedString(styled)
            dismissedMentionAt = nil
            textView.typingAttributes = Self.plainAttributes
            textView.setSelectedRange(NSRange(location: styled.length, length: 0))
            textView.needsDisplay = true
            contentDidChange()
            reportMentionQuery()
        }
    }

    /// What Enter sends: mentions as "@<number>", with the JIDs they stand for, trimmed.
    var composed: ComposedText {
        let storage = draft
        var text = ""
        var mentions: [String] = []
        storage.enumerateAttribute(.composeMention, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let mention = value as? ComposeMention, storage.attributedSubstring(from: range).string == "@" + mention.name {
                text += "@" + mention.user
                if let jid = mention.jid, !mentions.contains(jid) { mentions.append(jid) }
            } else {
                text += storage.attributedSubstring(from: range).string
            }
        }
        return ComposedText(text: text.trimmingCharacters(in: .whitespacesAndNewlines), mentions: mentions)
    }

    /// `text` (wire form) for editing: its mentions by name, going out as the numbers they came as.
    static func editable(_ text: String, mentions: [String: Mention]) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text)
        for token in Mentions.ranges(in: text).reversed() {
            guard let mention = mentions[token.user] else { continue }
            s.replaceCharacters(in: token.range, with: NSAttributedString(
                string: "@" + mention.name, attributes: [.composeMention: ComposeMention(name: mention.name, user: token.user, jid: mention.jid)]))
        }
        return s
    }

    /// Replaces the "@<query>" being typed with a mention of `name`, and a space.
    func insertMention(_ mention: ComposeMention) {
        guard let query = activeMentionQuery() else { return }
        let token = NSMutableAttributedString(string: "@" + mention.name, attributes: Self.plainAttributes)
        token.addAttributes(Self.mentionAttributes(mention), range: NSRange(location: 0, length: token.length))
        token.append(NSAttributedString(string: " ", attributes: Self.plainAttributes))
        guard textView.shouldChangeText(in: query.range, replacementString: token.string) else { return }
        textView.textStorage?.replaceCharacters(in: query.range, with: token)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: query.range.location + token.length, length: 0))
        textView.typingAttributes = Self.plainAttributes
    }

    private static var plainAttributes: [NSAttributedString.Key: Any] {
        [.font: MessageTextConfiguration.body, .foregroundColor: NSColor.labelColor]
    }

    private static func mentionAttributes(_ mention: ComposeMention) -> [NSAttributedString.Key: Any] {
        [.composeMention: mention, .foregroundColor: MarkdownLite.linkColor]
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
            barSnippet.attributedStringValue = snippet
            barAccent.layer?.backgroundColor = color.cgColor
        case .edit:
            barTitle.stringValue = "Edit message"
            barTitle.textColor = Palette.green
            barSnippet.stringValue = "Enter to save · Esc to cancel"
            barAccent.layer?.backgroundColor = Palette.green.cgColor
        case nil:
            break
        }
        barView.isHidden = bar == nil
        barHeight.constant = bar == nil ? 0 : 40
        // A hidden bar takes no space, or the editor row sits below the pill's center.
        barTop.constant = bar == nil ? 0 : 8
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

    /// Esc: closes the mention picker, else clears the bar (and edit text); returns false when there
    /// was nothing to clear.
    @discardableResult
    func handleEscape() -> Bool {
        mentionKey(.dismiss) || clearBar()
    }

    @discardableResult
    private func clearBar() -> Bool {
        guard bar != nil else { return false }
        if case .edit = bar { text = "" }
        setBar(nil)
        onCancelBar?()
        return true
    }

    // MARK: - Actions

    @objc private func sendTapped() { send() }
    @objc private func attachTapped() { onAttach?() }
    @objc private func cancelBar() { clearBar() }

    private func send() {
        let composed = composed
        guard !composed.text.isEmpty || hasAttachments else { return }
        onSend?(composed)
    }

    /// Called by the owner after a successful send/edit hand-off.
    func clearAfterSend() {
        textView.string = ""
        textView.undoManager?.removeAllActions()
        setBar(nil)
        contentDidChange()
    }

    // MARK: - NSTextViewDelegate

    /// Only user edits reach this; programmatic `string` assignments don't post the notification.
    func textDidChange(_ notification: Notification) {
        contentDidChange()
        onTyping?()
        reportMentionQuery()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        reportMentionQuery()
    }

    /// Text typed next to a mention is plain.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
        newTypingAttributes[.composeMention] == nil ? newTypingAttributes : Self.plainAttributes
    }

    private var rewritingMention = false

    /// Deleting into a mention deletes all of it; typing inside one turns it into plain text. Either
    /// is a single text change, so undo brings the mention back whole.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !rewritingMention, !textView.hasMarkedText(), let replacement = replacementString,
              let expanded = mentionsTouched(by: range) else { return true }
        let deleting = replacement.isEmpty
        var text = ""
        if !deleting, let storage = textView.textStorage {
            let plain = NSMutableString(string: storage.attributedSubstring(from: expanded).string)
            plain.replaceCharacters(in: NSRange(location: range.location - expanded.location, length: range.length), with: replacement)
            text = plain as String
        }
        guard rewrite(expanded, as: text) else { return false }
        let caret = deleting ? expanded.location : range.location + (replacement as NSString).length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        return false
    }

    /// An input method composing inside a mention: the mention turns plain first, as its own change,
    /// and the composition then proceeds as usual.
    private func plainMentions(touching range: NSRange) {
        guard let expanded = mentionsTouched(by: range), let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        guard rewrite(expanded, as: storage.attributedSubstring(from: expanded).string) else { return }
        textView.setSelectedRange(selection)
    }

    /// `range` grown to the whole of each mention it overlaps (or, empty, falls strictly inside); nil
    /// when it touches none.
    private func mentionsTouched(by range: NSRange) -> NSRange? {
        guard let storage = textView.textStorage else { return nil }
        var expanded = range
        storage.enumerateAttribute(.composeMention, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
            let touched = range.length > 0 ? NSIntersectionRange(run, range).length > 0
                                           : run.location < range.location && range.location < NSMaxRange(run)
            if value != nil, touched { expanded = NSUnionRange(expanded, run) }
        }
        return expanded == range ? nil : expanded
    }

    /// Replaces `range` with plain `text` as one undoable change.
    private func rewrite(_ range: NSRange, as text: String) -> Bool {
        rewritingMention = true
        defer { rewritingMention = false }
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: text) else { return false }
        textView.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: Self.plainAttributes))
        textView.didChangeText()
        textView.typingAttributes = Self.plainAttributes
        return true
    }

    // MARK: - Mention query

    /// Where Esc closed the picker; it stays closed for that "@".
    private var dismissedMentionAt: Int?
    private var lastMentionQuery: String?

    /// The "@<query>" before the caret: "@" starts a word, and the query is one line of at most 40
    /// characters that doesn't start with a space.
    private func activeMentionQuery() -> (range: NSRange, query: String)? {
        guard mentionsEnabled, let storage = textView.textStorage else { return nil }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        let ns = storage.string as NSString
        let cursor = selection.location
        var i = cursor - 1
        while i >= 0, cursor - i <= 41 {
            let c = ns.character(at: i)
            if c == 0x0A { return nil }
            if c == 0x40 /* @ */ {
                if i > 0, let prev = Unicode.Scalar(ns.character(at: i - 1)), !CharacterSet.whitespacesAndNewlines.contains(prev),
                   !"([{\"'".unicodeScalars.contains(prev) { return nil }
                if storage.attribute(.composeMention, at: i, effectiveRange: nil) != nil { return nil }
                let range = NSRange(location: i, length: cursor - i)
                let query = ns.substring(with: NSRange(location: i + 1, length: cursor - i - 1))
                return query.hasPrefix(" ") ? nil : (range, query)
            }
            i -= 1
        }
        return nil
    }

    private func reportMentionQuery() {
        let active = activeMentionQuery()
        if active?.range.location != dismissedMentionAt { dismissedMentionAt = nil }
        let query = dismissedMentionAt == nil ? active?.query : nil
        guard query != lastMentionQuery else { return }
        lastMentionQuery = query
        onMentionQuery?(query)
    }

    private func mentionKey(_ key: MentionKey) -> Bool {
        guard lastMentionQuery != nil, onMentionKey?(key) == true else { return false }
        if key == .dismiss {
            dismissedMentionAt = activeMentionQuery()?.range.location
            reportMentionQuery()
        }
        return true
    }

    /// Chat isn't prose: skip the system "Capitalize words automatically" pass, keep spelling fixes.
    func textView(_ view: NSTextView, willCheckTextIn range: NSRange, options: [NSSpellChecker.OptionKey: Any], types checkingTypes: UnsafeMutablePointer<NSTextCheckingTypes>) -> [NSSpellChecker.OptionKey: Any] {
        options.merging([.automaticCapitalizationEnabledKey: false]) { _, new in new }
    }

    private func contentDidChange() {
        updateSendEnabled()
        updateHeight()
    }

    private func updateSendEnabled() {
        sendButton.isEnabled = !textView.isEmpty || hasAttachments
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            if mentionKey(.accept) { return true }
            send()
            return true
        case #selector(NSResponder.insertTab(_:)):
            return mentionKey(.accept)
        case #selector(NSResponder.moveDown(_:)):
            return mentionKey(.down)
        case #selector(NSResponder.moveUp(_:)):
            if mentionKey(.up) { return true }
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
        let pill = barTop.constant + barHeight.constant + trayHeight.constant + 5 + h + 5
        let total = Self.outerInsets.top + Self.outerInsets.bottom + pill
        onHeightChange?(ceil(total))
    }
}

/// A message as composed: mentions as "@<number>", and the JIDs they stand for.
struct ComposedText: Equatable {
    var text: String
    var mentions: [String] = []
}

/// A mention in the compose editor. `user` is the number its "@<number>" goes out as.
final class ComposeMention: NSObject {
    let name: String
    let user: String
    /// The JID a sent message lists; nil for a mention kept from an edited message without one.
    let jid: String?

    init(name: String, user: String, jid: String?) {
        self.name = name
        self.user = user
        self.jid = jid
    }
}

extension NSAttributedString.Key {
    /// The `ComposeMention` behind an "@<name>" in the compose editor.
    static let composeMention = NSAttributedString.Key("CmdFreakComposeMention")
}
