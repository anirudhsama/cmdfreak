import AppKit

/// WhatsApp-style search capsule that floats in glass over the top of the chat list; rows scroll
/// underneath it. Filters the list by chat name as you type.
@MainActor
final class ChatSearchBar: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 36

    var onChange: ((String) -> Void)?
    /// ↓ or Return: hand keyboard focus to the list.
    var onCommit: (() -> Void)?

    private let glass = NSGlassEffectView()
    private let field = NSTextField()
    private let icon = NSImageView()
    private let clearButton = NSButton()

    var text: String { field.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = Self.height / 2
        glass.style = .regular
        addSubview(glass)
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = content

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear Search")
        clearButton.isBordered = false
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.isHidden = true

        for v in [icon, field, clearButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),

            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 13),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            field.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),
            clearButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            clearButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Clicks anywhere on the capsule edit the field.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    func focus() {
        window?.makeFirstResponder(field)
    }

    @objc func clear() {
        field.stringValue = ""
        textChanged()
    }

    private func textChanged() {
        clearButton.isHidden = field.stringValue.isEmpty
        onChange?(field.stringValue)
    }

    func controlTextDidChange(_ obj: Notification) { textChanged() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { onCommit?() } else { clear() }
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
            onCommit?()
            return true
        default:
            return false
        }
    }
}
