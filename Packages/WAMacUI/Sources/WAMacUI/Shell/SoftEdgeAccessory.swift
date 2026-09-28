import AppKit

/// A split view item's top accessory that content scrolls beneath with a soft, fading edge (the
/// AppKit counterpart of SwiftUI's `scrollEdgeEffectStyle(.soft, for: .top)`). Without it the
/// scroll view under the toolbar gets a hard cutoff.
@MainActor
final class SoftEdgeAccessory: NSSplitViewItemAccessoryViewController {
    init(content: NSView, insets: NSEdgeInsets) {
        super.init(nibName: nil, bundle: nil)
        let root = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -insets.bottom),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -insets.right),
        ])
        view = root
        automaticallyAppliesContentInsets = false
        if #available(macOS 26.1, *) {
            preferredScrollEdgeEffectStyle = .soft
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
