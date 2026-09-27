import AppKit

/// Title and subtitle of the open chat, shown in the toolbar over the conversation column.
@MainActor
final class ChatTitleView: NSStackView {
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        for field in [titleField, subtitleField] {
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addArrangedSubview(field)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(title: String, subtitle: String) {
        titleField.stringValue = title
        subtitleField.stringValue = subtitle
        subtitleField.isHidden = subtitle.isEmpty
    }
}
