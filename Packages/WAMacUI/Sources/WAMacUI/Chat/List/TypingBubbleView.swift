import AppKit

/// The message list's trailing row while someone in the open chat is typing: an incoming bubble
/// under the newest message.
final class TypingCell: NSView {
    let bubble = TypingBubbleView()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(bubble)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard let typing = bubble.typing else { return }
        let size = TypingBubbleView.size(for: typing)
        bubble.frame = CGRect(x: MessageTextConfiguration.Metrics.horizontalInset - MessageCell.tailOverhang,
                              y: MessageTextConfiguration.Metrics.messageGap, width: size.width, height: size.height)
    }
}

/// An incoming bubble with three pulsing dots; a mic leads the dots while they record audio. In
/// groups the sender line sits on top, as it does on their messages.
final class TypingBubbleView: NSView {
    private typealias M = MessageTextConfiguration.Metrics
    private typealias C = MessageTextConfiguration

    private static let dotSize: CGFloat = 7
    private static let dotGap: CGFloat = 4
    private static let rowHeight: CGFloat = 20
    private static let micWidth: CGFloat = 16
    private static let maxSenderWidth: CGFloat = 280

    private let mic = NSImageView()
    private let dots = (0..<3).map { _ in CALayer() }
    private(set) var typing: ChatTyping?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        mic.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        mic.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        mic.contentTintColor = .secondaryLabelColor
        addSubview(mic)
        for dot in dots {
            dot.cornerRadius = Self.dotSize / 2
            layer?.addSublayer(dot)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        applyColors()
        NotificationCenter.default.addObserver(self, selector: #selector(displayOptionsChanged),
                                               name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                               object: NSWorkspace.shared)
    }

    @objc private func displayOptionsChanged() { animateDots() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ typing: ChatTyping) {
        guard typing != self.typing else { return }
        self.typing = typing
        mic.isHidden = !typing.recording
        setAccessibilityLabel(typing.text)
        needsLayout = true
        needsDisplay = true
        superview?.needsLayout = true
    }

    /// Including the tail's overhang on the leading side.
    static func size(for typing: ChatTyping) -> NSSize {
        let dotsWidth = 3 * dotSize + 2 * dotGap + (typing.recording ? micWidth + 4 : 0)
        let senderWidth = typing.who.map { min(ceil(senderLine($0, typing).size().width), maxSenderWidth) } ?? 0
        let height = 2 * M.bubblePaddingV + rowHeight + (typing.who == nil ? 0 : M.senderHeight + 1)
        return NSSize(width: MessageCell.tailOverhang + max(dotsWidth, senderWidth, 20) + 2 * M.bubblePaddingH, height: height)
    }

    private static func senderLine(_ who: String, _ typing: ChatTyping) -> NSAttributedString {
        let color = typing.senders.count == 1 ? C.senderColor(for: typing.senders[0].jid) : .secondaryLabelColor
        return NSAttributedString(string: who, attributes: [.font: C.sender, .foregroundColor: color])
    }

    private var bubbleRect: CGRect {
        CGRect(x: MessageCell.tailOverhang, y: 0, width: bounds.width - MessageCell.tailOverhang, height: bounds.height)
    }

    override func layout() {
        super.layout()
        let bubble = bubbleRect
        let y = M.bubblePaddingV + (typing?.who == nil ? 0 : M.senderHeight + 1)
        var x = bubble.minX + M.bubblePaddingH
        if !mic.isHidden {
            mic.frame = CGRect(x: x, y: y, width: Self.micWidth, height: Self.rowHeight)
            x += Self.micWidth + 4
        }
        let dotY = y + (Self.rowHeight - Self.dotSize) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, dot) in dots.enumerated() {
            dot.frame = CGRect(x: x + CGFloat(i) * (Self.dotSize + Self.dotGap), y: dotY, width: Self.dotSize, height: Self.dotSize)
        }
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let bubble = bubbleRect
        C.incomingBubble.setFill()
        NSBezierPath(roundedRect: bubble, xRadius: M.bubbleRadius, yRadius: M.bubbleRadius).fill()
        MessageCell.tailPath(for: bubble, outgoing: false).fill()
        if let typing, let who = typing.who {
            let rect = CGRect(x: bubble.minX + M.bubblePaddingH, y: M.bubblePaddingV,
                              width: bubble.width - 2 * M.bubblePaddingH, height: M.senderHeight)
            Self.senderLine(who, typing).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animateDots()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for dot in dots { dot.backgroundColor = NSColor.secondaryLabelColor.cgColor }
        }
    }

    /// Each dot pulses in turn, a beat apart; held steady under Reduce Motion.
    private func animateDots() {
        for dot in dots { dot.removeAnimation(forKey: "pulse") }
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let start = CACurrentMediaTime()
        for (i, dot) in dots.enumerated() {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.3
            pulse.toValue = 1
            pulse.duration = 0.45
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.beginTime = start + Double(i) * 0.15
            pulse.fillMode = .backwards
            dot.add(pulse, forKey: "pulse")
        }
    }
}
