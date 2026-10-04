import AppKit

/// The liquid-glass buttons beside a hovered bubble: react (opens the reaction bar) and reply.
/// Placed by `MessageCell` in its own coordinates.
final class MessageHoverActions: NSView {
    var onReact: (() -> Void)?
    var onReply: (() -> Void)?

    private let container = NSGlassEffectContainerView()
    private let reactGlass = NSGlassEffectView()
    private let replyGlass = NSGlassEffectView()
    private let react = NSButton()
    private let reply = NSButton()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        container.spacing = 8
        let content = NSView()
        container.contentView = content
        addSubview(container)
        for (glass, button, symbol, label, action) in [
            (reactGlass, react, "face.smiling", "React", #selector(reactClicked)),
            (replyGlass, reply, "arrowshape.turn.up.left", "Reply", #selector(replyClicked)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.toolTip = label
            button.target = self
            button.action = action
            glass.style = .regular
            glass.contentView = button
            content.addSubview(glass)
        }
        // Dark appearance draws face.smiling filled in; keep its glyph on aqua and tint it for the
        // real appearance instead.
        react.appearance = NSAppearance(named: .aqua)
        updateTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Both frames in the superview's coordinates.
    func place(react reactFrame: NSRect, reply replyFrame: NSRect) {
        let all = reactFrame.union(replyFrame)
        frame = all
        container.frame = bounds
        container.contentView?.frame = bounds
        reactGlass.frame = reactFrame.offsetBy(dx: -all.minX, dy: -all.minY)
        replyGlass.frame = replyFrame.offsetBy(dx: -all.minX, dy: -all.minY)
        reactGlass.cornerRadius = reactFrame.height / 2
        replyGlass.cornerRadius = replyFrame.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    private func updateTint() {
        var tint = NSColor.gray
        effectiveAppearance.performAsCurrentDrawingAppearance { tint = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? .gray }
        react.contentTintColor = tint
        reply.contentTintColor = .secondaryLabelColor
    }

    @objc private func reactClicked() { onReact?() }
    @objc private func replyClicked() { onReply?() }
}
