import AppKit

/// Title and subtitle in the toolbar (the chat list's filter name, centered over the list).
/// The lines are placed by baseline, as the window's own title and subtitle are.
@MainActor
final class ChatTitleView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private var twoLine: [NSLayoutConstraint] = []
    private var oneLine: [NSLayoutConstraint] = []

    init(centered: Bool = false) {
        super.init(frame: .zero)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        for field in [titleField, subtitleField] {
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            if centered {
                field.alignment = .center
                NSLayoutConstraint.activate([
                    field.centerXAnchor.constraint(equalTo: centerXAnchor),
                    field.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
                    widthAnchor.constraint(greaterThanOrEqualTo: field.widthAnchor),
                ])
                continue
            }
            let fill = field.trailingAnchor.constraint(equalTo: trailingAnchor)
            fill.priority = .defaultLow
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor),
                field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                fill,
            ])
        }
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        twoLine = [
            titleField.firstBaselineAnchor.constraint(equalTo: topAnchor, constant: 13),
            subtitleField.firstBaselineAnchor.constraint(equalTo: topAnchor, constant: 27),
        ]
        oneLine = [titleField.centerYAnchor.constraint(equalTo: centerYAnchor)]
        NSLayoutConstraint.activate(twoLine)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(title: String, subtitle: String) {
        titleField.stringValue = title
        subtitleField.stringValue = subtitle
        subtitleField.isHidden = subtitle.isEmpty
        NSLayoutConstraint.deactivate(subtitle.isEmpty ? twoLine : oneLine)
        NSLayoutConstraint.activate(subtitle.isEmpty ? oneLine : twoLine)
    }
}
