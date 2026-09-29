import AppKit
import Observation
import SwiftUI

/// The open chat's identity, set by the window controller.
@MainActor @Observable
final class ChatHeaderModel {
    var state: ChatRowState?
    var subtitle = ""
    /// Who is typing in the open chat; kept apart from `state`, which is nil or stale when the
    /// current filter has no row for the chat.
    var typing: ChatTyping?
}

/// Avatar, then the name with the subtitle (phone, participant count, or who is typing) under it,
/// leading-aligned in the toolbar strip over the conversation.
@MainActor
final class ChatHeaderView: NSView {
    static let avatarSize: CGFloat = 28

    private let model: ChatHeaderModel
    private let avatar: NSHostingView<HeaderAvatar>
    private let nameField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private var nameCentered: NSLayoutConstraint!
    private var nameAbove: NSLayoutConstraint!
    private var token: ObservationToken?

    init(model: ChatHeaderModel) {
        self.model = model
        avatar = NSHostingView(rootView: HeaderAvatar(model: model))
        super.init(frame: .zero)

        avatar.sizingOptions = []
        // It sits in the toolbar strip; don't let SwiftUI pad it out of the safe area.
        avatar.safeAreaRegions = []
        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        for field in [nameField, subtitleField] {
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for v in [avatar, nameField, subtitleField] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        nameCentered = nameField.centerYAnchor.constraint(equalTo: centerYAnchor)
        // Same baselines as the chat list's title and subtitle (`ChatTitleView`), so the rows line up.
        nameAbove = nameField.lastBaselineAnchor.constraint(equalTo: centerYAnchor, constant: -2)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),

            nameField.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 9),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            subtitleField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            subtitleField.firstBaselineAnchor.constraint(equalTo: nameField.lastBaselineAnchor, constant: 14),
        ])

        token = WAMacUI.observe { [weak self] in
            guard let self else { return }
            nameField.stringValue = model.state?.title ?? ""
            let activity = model.typing?.text
            let subtitle = activity ?? model.subtitle
            subtitleField.stringValue = subtitle
            subtitleField.textColor = activity == nil ? .secondaryLabelColor : Palette.green
            let twoLine = !subtitle.isEmpty
            subtitleField.isHidden = !twoLine
            nameCentered.isActive = !twoLine
            nameAbove.isActive = twoLine
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private struct HeaderAvatar: View {
    let model: ChatHeaderModel

    var body: some View {
        if let state = model.state {
            AvatarView(state: state, size: ChatHeaderView.avatarSize)
        }
    }
}
