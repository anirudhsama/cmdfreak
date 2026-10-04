import AppKit

/// WhatsApp's quick reaction bar: a glass capsule of emoji over a message, the current reaction
/// ringed, and a "+" that opens the system emoji picker. The quick six come first; recently used
/// others follow, scrolled into view sideways. A borderless child panel of the chat window. 1–6
/// pick, Esc closes; a click elsewhere, the panel losing key or the app deactivating dismisses it.
@MainActor
final class ReactionPicker: NSObject, NSWindowDelegate {
    nonisolated static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    let messageId: String
    var onClose: (() -> Void)?
    /// Clicks here only dismiss, so clicking the same smiley doesn't reopen the bar; clicks
    /// elsewhere dismiss and go through.
    weak var dismissOnlyView: NSView?

    private let current: String?
    private let onPick: (String) -> Void
    private let size: NSSize
    private let panel: PickerPanel
    private let sink = EmojiSink()
    private weak var owner: NSWindow?
    private var mouseMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?
    /// The system emoji picker may take key from the panel; that must not close it.
    private var paletteOpen = false
    private var isClosed = false

    private static let item: CGFloat = 40
    private static let padding: CGFloat = 6
    private static let spacing: CGFloat = 2

    init(messageId: String, current: String?, onPick: @escaping (String) -> Void) {
        self.messageId = messageId
        self.current = current
        self.onPick = onPick
        let emoji = Self.quickReactions + RecentReactions.all
        let step = Self.item + Self.spacing
        let quickWidth = step * CGFloat(Self.quickReactions.count)
        let overflows = emoji.count > Self.quickReactions.count
        // With recents, the next one peeks out from under the "+", as in WhatsApp, hinting at the scroll.
        let peek = overflows ? Self.item / 2 : 0
        // Runs on under the "+" to its center.
        let stripWidth = quickWidth + peek + (overflows ? Self.item / 2 : 0)
        size = NSSize(width: Self.padding * 2 + quickWidth + peek + Self.item, height: Self.item + Self.padding * 2)
        panel = PickerPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]

        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = size.height / 2
        glass.style = .regular
        let content = PickerContentView(frame: glass.bounds)
        content.onKey = { [weak self] in self?.handleKey($0) ?? false }
        glass.contentView = content
        panel.contentView = glass

        // Under the "+" so the emoji picker opens beside it; added first so the button takes clicks.
        let plusFrame = NSRect(x: size.width - Self.padding - Self.item, y: Self.padding, width: Self.item, height: Self.item)
        sink.frame = plusFrame
        sink.onEmoji = { [weak self] in self?.pick($0) }
        // Keys typed while the palette flow holds focus still reach the shortcuts.
        sink.onKey = { [weak self] in self?.handleKey($0) ?? false }
        content.addSubview(sink)

        let strip = SidewaysScrollView(frame: NSRect(x: Self.padding, y: Self.padding, width: stripWidth, height: Self.item))
        // Trailing room so the last recent scrolls clear of the "+".
        let document = NSView(frame: NSRect(x: 0, y: 0, width: step * CGFloat(emoji.count) - Self.spacing + (overflows ? Self.item / 2 + Self.spacing : 0),
                                            height: Self.item))
        for (i, e) in emoji.enumerated() {
            let v = PickerItem(kind: .emoji(e), selected: e == current)
            v.frame = NSRect(x: step * CGFloat(i), y: 0, width: Self.item, height: Self.item)
            v.onClick = { [weak self] in self?.pick(e) }
            document.addSubview(v)
        }
        strip.documentView = document
        content.addSubview(strip)

        let plus = PickerItem(kind: .more, selected: false)
        plus.frame = plusFrame
        plus.onClick = { [weak self] in self?.openEmojiPalette() }
        content.addSubview(plus)
    }

    /// `anchor` (the react button, or the bubble) and `bounds` (the visible message list) are in
    /// screen coordinates. Sits just above the anchor, centered on it, or below it when there is no
    /// room above.
    func show(in owner: NSWindow, anchor: NSRect, bounds: NSRect) {
        self.owner = owner
        let s = size
        let x = min(max(anchor.midX - s.width / 2, bounds.minX + 8), bounds.maxX - 8 - s.width)
        var y = anchor.maxY + 6
        if y + s.height > bounds.maxY - 4 { y = anchor.minY - 6 - s.height }
        y = min(max(y, bounds.minY + 8), bounds.maxY - 8 - s.height)
        let frame = NSRect(x: x.rounded(), y: y.rounded(), width: s.width, height: s.height)

        owner.addChildWindow(panel, ordered: .above)
        panel.setFrame(frame.offsetBy(dx: 0, dy: -6), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView.flatMap { ($0 as? NSGlassEffectView)?.contentView })
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, event.window !== self.panel else { return event }
            self.close()
            guard let v = self.dismissOnlyView, v.window === event.window,
                  v.bounds.contains(v.convert(event.locationInWindow, from: nil)) else { return event }
            return nil
        }
        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.close(restoringFocus: false) } }
    }

    /// `restoringFocus`: hand key back to the chat window. Not when focus already went elsewhere.
    func close(restoringFocus: Bool = true) {
        guard !isClosed else { return }
        isClosed = true
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        deactivateObserver = nil
        panel.delegate = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if restoringFocus, NSApp.isActive, panel.isKeyWindow || NSApp.keyWindow == nil, owner?.isVisible == true { owner?.makeKey() }
        onClose?()
    }

    isolated deinit { close(restoringFocus: false) }

    private func pick(_ emoji: String) {
        if emoji != current { RecentReactions.note(emoji) }
        onPick(emoji)
        close()
    }

    private func openEmojiPalette() {
        paletteOpen = true
        panel.makeFirstResponder(sink)
        NSApp.orderFrontCharacterPalette(sink)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.keyCode == 53 {  // Esc
            close()
            return true
        }
        if let c = event.charactersIgnoringModifiers, let n = Int(c), (1...Self.quickReactions.count).contains(n) {
            pick(Self.quickReactions[n - 1])
            return true
        }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard paletteOpen else { return close(restoringFocus: false) }
        // The emoji palette may take key for itself; another of this app's windows taking it means
        // the user moved on.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let key = NSApp.keyWindow, key !== self.panel else { return }
                self.close(restoringFocus: false)
            }
        }
    }

    /// Back from the emoji palette without a choice: shortcuts and dismiss-on-blur apply again.
    func windowDidBecomeKey(_ notification: Notification) {
        guard paletteOpen else { return }
        paletteOpen = false
        panel.makeFirstResponder((panel.contentView as? NSGlassEffectView)?.contentView)
    }
}

/// Emoji reacted with from outside the quick six, newest first; the bar lists them after the six.
enum RecentReactions {
    static let limit = 6
    private static let key = "recentReactions"

    static var all: [String] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { !ReactionPicker.quickReactions.contains($0) }
    }

    static func note(_ emoji: String) {
        guard !ReactionPicker.quickReactions.contains(emoji) else { return }
        UserDefaults.standard.set(Array(([emoji] + all.filter { $0 != emoji }).prefix(limit)), forKey: key)
    }
}

/// The emoji strip: scrolls only sideways, and a mouse wheel's vertical turn scrolls it too.
private final class SidewaysScrollView: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return super.scrollWheel(with: event) }
        let clip = contentView
        let maxX = max(0, (documentView?.frame.width ?? 0) - clip.bounds.width)
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
        clip.setBoundsOrigin(NSPoint(x: min(max(clip.bounds.minX - delta, 0), maxX), y: clip.bounds.minY))
        reflectScrolledClipView(clip)
    }
}

private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PickerContentView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

/// Invisible text input that receives the system emoji picker's choice.
private final class EmojiSink: NSTextView {
    var onEmoji: ((String) -> Void)?
    var onKey: ((NSEvent) -> Bool)?

    convenience init() {
        self.init(frame: .zero)
        drawsBackground = false
        insertionPointColor = .clear
        isRichText = false
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard let first = s.first, Self.isEmoji(first) else { return }
        onEmoji?(String(first))
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    /// Digits and # are emoji-capable scalars too; only take ones that render as emoji.
    private static func isEmoji(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first, scalar.properties.isEmoji else { return false }
        return scalar.properties.isEmojiPresentation || c.unicodeScalars.count > 1
    }
}

/// Selection and hover sit in a circle that darkens (light) or lightens (dark) the glass behind it,
/// the way system vibrant fills do, rather than laying grey over it.
private final class PickerItem: NSView {
    enum Kind {
        case emoji(String)
        case more
    }

    let kind: Kind
    let selected: Bool
    var onClick: (() -> Void)?
    private let highlight = NSView()
    private let glyph = GlyphView()
    private var hovering = false {
        didSet {
            guard oldValue != hovering else { return }
            updateHighlight()
            glyph.needsDisplay = true
        }
    }

    init(kind: Kind, selected: Bool) {
        self.kind = kind
        self.selected = selected
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        switch kind {
        case .emoji(let e): setAccessibilityLabel(e)
        case .more: setAccessibilityLabel("More reactions")
        }
        highlight.wantsLayer = true
        highlight.autoresizingMask = [.width, .height]
        addSubview(highlight)
        glyph.item = self
        glyph.autoresizingMask = [.width, .height]
        addSubview(glyph)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        highlight.frame = bounds.insetBy(dx: 1, dy: 1)
        glyph.frame = bounds
        updateHighlight()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHighlight()
    }

    private func updateHighlight() {
        guard let layer = highlight.layer else { return }
        guard case .emoji = kind, selected || hovering else {
            layer.isHidden = true
            return
        }
        let dark = effectiveAppearance.isDark
        // plusDarker subtracts (1 − white) from what is behind; plusLighter adds white. The selected
        // amount matches the system's selected segment on glass (239 over 255 in light).
        let amount: CGFloat = selected ? (dark ? 0.10 : 0.065) : (dark ? 0.05 : 0.035)
        layer.isHidden = false
        layer.cornerRadius = highlight.bounds.height / 2
        layer.backgroundColor = NSColor(white: dark ? amount : 1 - amount, alpha: 1).cgColor
        layer.compositingFilter = dark ? "plusL" : "plusD"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    fileprivate func drawGlyph(in r: NSRect) {
        switch kind {
        case .emoji(let e):
            let text = NSAttributedString(string: e, attributes: [.font: NSFont.systemFont(ofSize: hovering ? 28 : 25)])
            let s = text.size()
            text.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
        case .more:
            // Opaque, so a recent scrolled under it stays hidden.
            let d: CGFloat = 30
            let circle = NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
            (hovering ? NSColor.systemGray.blended(withFraction: 0.2, of: .labelColor) ?? .systemGray : .systemGray).setFill()
            NSBezierPath(ovalIn: circle).fill()
            guard let img = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))?.tinted(.white) else { return }
            let s = img.size
            img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
        }
    }
}

private final class GlyphView: NSView {
    weak var item: PickerItem?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { item?.drawGlyph(in: bounds) }
}
