import AppKit

/// Horizontal strip of staged attachments inside the compose pill. Each tile shows a thumbnail
/// (or the file icon), a spinner while metadata is computed, and a remove button.
final class AttachmentTrayView: NSView {
    struct Item: Equatable {
        enum State: Equatable { case preparing, ready, failed(String) }
        let id: UUID
        var name: String
        var image: NSImage?
        /// Documents show their icon and name instead of a full-bleed thumbnail.
        var isDocument: Bool
        var badge: String?
        var state: State
    }

    static let height: CGFloat = 76
    static let tile: CGFloat = 64

    var onRemove: ((UUID) -> Void)?

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var tiles: [UUID: Tile] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 6),
            doc.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            stack.heightAnchor.constraint(equalToConstant: Self.tile),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(_ items: [Item]) {
        let ids = Set(items.map(\.id))
        for (id, tile) in tiles where !ids.contains(id) {
            stack.removeArrangedSubview(tile)
            tile.removeFromSuperview()
            tiles[id] = nil
        }
        var added = false
        for item in items {
            if let tile = tiles[item.id] {
                tile.configure(item)
            } else {
                let tile = Tile(id: item.id)
                tile.onRemove = { [weak self] id in self?.onRemove?(id) }
                tile.configure(item)
                tiles[item.id] = tile
                stack.addArrangedSubview(tile)  // items only ever append or disappear, so order holds
                added = true
            }
        }
        if added, let last = items.last, let tile = tiles[last.id] {
            layoutSubtreeIfNeeded()
            tile.scrollToVisible(tile.bounds)
        }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class Tile: NSView {
        let id: UUID
        var onRemove: ((UUID) -> Void)?
        private let imageView = NSImageView()
        private let nameLabel = NSTextField(labelWithString: "")
        private let badgeLabel = NSTextField(labelWithString: "")
        private let spinner = NSProgressIndicator()
        private let warning = NSImageView()
        private let remove = NSButton()

        init(id: UUID) {
            self.id = id
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 10
            layer?.masksToBounds = true
            layer?.backgroundColor = MessageTextConfiguration.quoteBackground.cgColor
            translatesAutoresizingMaskIntoConstraints = false

            imageView.translatesAutoresizingMaskIntoConstraints = true  // framed in layout()
            nameLabel.font = .systemFont(ofSize: 9)
            nameLabel.textColor = .secondaryLabelColor
            nameLabel.alignment = .center
            nameLabel.lineBreakMode = .byTruncatingMiddle
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            badgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
            badgeLabel.textColor = .white
            badgeLabel.wantsLayer = true
            badgeLabel.drawsBackground = true
            badgeLabel.backgroundColor = NSColor.black.withAlphaComponent(0.55)
            badgeLabel.translatesAutoresizingMaskIntoConstraints = false
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.translatesAutoresizingMaskIntoConstraints = false
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Can't attach")
            warning.contentTintColor = .systemYellow
            warning.translatesAutoresizingMaskIntoConstraints = false
            remove.bezelStyle = .accessoryBarAction
            remove.isBordered = false
            remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)
                    .applying(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.55)])))
            remove.target = self
            remove.action = #selector(removeTapped)
            remove.translatesAutoresizingMaskIntoConstraints = false
            remove.toolTip = "Remove"
            for v in [imageView, nameLabel, badgeLabel, spinner, warning, remove] { addSubview(v) }
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: AttachmentTrayView.tile),
                heightAnchor.constraint(equalToConstant: AttachmentTrayView.tile),
                spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
                warning.centerXAnchor.constraint(equalTo: centerXAnchor),
                warning.centerYAnchor.constraint(equalTo: centerYAnchor),
                remove.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                remove.widthAnchor.constraint(equalToConstant: 18),
                remove.heightAnchor.constraint(equalToConstant: 18),
                badgeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                badgeLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
                nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
                nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
                nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func configure(_ item: Item) {
            imageView.image = item.image
            nameLabel.stringValue = item.name
            nameLabel.isHidden = !item.isDocument
            badgeLabel.stringValue = item.badge.map { " \($0) " } ?? ""
            badgeLabel.isHidden = item.badge == nil || item.isDocument
            toolTip = item.name
            imageView.imageScaling = item.isDocument ? .scaleProportionallyUpOrDown : .scaleAxesIndependently
            switch item.state {
            case .preparing:
                spinner.isHidden = false
                spinner.startAnimation(nil)
                warning.isHidden = true
            case .ready:
                spinner.stopAnimation(nil)
                spinner.isHidden = true
                warning.isHidden = true
            case .failed(let reason):
                spinner.stopAnimation(nil)
                spinner.isHidden = true
                warning.isHidden = false
                toolTip = reason
            }
            needsLayout = true
        }

        override func layout() {
            super.layout()
            if nameLabel.isHidden {
                // Aspect-fill the square tile.
                guard let size = imageView.image?.size, size.width > 0, size.height > 0 else {
                    imageView.frame = bounds
                    return
                }
                let s = max(bounds.width / size.width, bounds.height / size.height)
                let w = size.width * s, h = size.height * s
                imageView.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
            } else {
                imageView.frame = NSRect(x: (bounds.width - 34) / 2, y: bounds.height - 40, width: 34, height: 34)
            }
        }

        @objc private func removeTapped() { onRemove?(id) }
    }
}
