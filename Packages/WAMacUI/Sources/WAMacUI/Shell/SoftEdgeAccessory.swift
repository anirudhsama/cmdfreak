import AppKit

/// A split view item's top accessory that content scrolls beneath with a soft, fading edge (the
/// AppKit counterpart of SwiftUI's `scrollEdgeEffectStyle(.soft, for: .top)`). Without it the
/// scroll view under the toolbar gets a hard cutoff.
/// Every accessory is the same height, so the fade band lines up across columns.
@MainActor
final class SoftEdgeAccessory: NSSplitViewItemAccessoryViewController {
    static let height: CGFloat = 54

    init(content: NSView, horizontalInset: CGFloat) {
        super.init(nibName: nil, bundle: nil)
        let root = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            root.heightAnchor.constraint(equalToConstant: Self.height),
            content.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -horizontalInset),
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
