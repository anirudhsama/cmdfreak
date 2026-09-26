import AppKit

/// Root view for split-view panes. Auto Layout sizes the window from its content's fitting size on
/// first show; panes made only of scroll views and hosting views would fit to ~10pt and collapse
/// the window. This view advertises a default height (low compression resistance, so resizing
/// smaller still works) without constraining width.
final class ShellRootView: NSView {
    static let defaultHeight: CGFloat = 720

    override init(frame: NSRect) {
        super.init(frame: frame)
        setContentCompressionResistancePriority(.init(1), for: .vertical)
        setContentHuggingPriority(.init(1), for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.defaultHeight)
    }
}
