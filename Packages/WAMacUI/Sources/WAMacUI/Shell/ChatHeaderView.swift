import AppKit
import Observation
import SwiftUI

/// The open chat's identity, iMessage style: the avatar centered at the top of the thread with the
/// name in a glass capsule under it. The subtitle (phone or participant count) is the tooltip.
@MainActor @Observable
final class ChatHeaderModel {
    var state: ChatRowState?
    var subtitle = ""
}

/// The avatar over a glass name capsule.
@MainActor
final class ChatHeaderView: NSView {
    static let avatarSize: CGFloat = 26
    static let capsuleHeight: CGFloat = 20
    /// Capsule tucks this far under the avatar.
    static let overlap: CGFloat = 4

    private let model: ChatHeaderModel
    private let avatar: NSHostingView<HeaderAvatar>
    private let capsule = NSGlassEffectView()
    private let nameField = NSTextField(labelWithString: "")
    private var token: ObservationToken?

    init(model: ChatHeaderModel) {
        self.model = model
        avatar = NSHostingView(rootView: HeaderAvatar(model: model))
        super.init(frame: .zero)

        capsule.cornerRadius = Self.capsuleHeight / 2
        capsule.style = .regular
        let content = NSView()
        capsule.contentView = content
        nameField.font = .systemFont(ofSize: 11, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setContentHuggingPriority(.required, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(nameField)
        avatar.sizingOptions = []
        // It sits in the toolbar strip; don't let SwiftUI pad it out of the safe area.
        avatar.safeAreaRegions = []
        // Avatar above the capsule, overlapping its top edge.
        for v in [capsule, avatar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.topAnchor.constraint(equalTo: topAnchor),
            avatar.centerXAnchor.constraint(equalTo: centerXAnchor),

            capsule.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: -Self.overlap),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
            capsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            capsule.heightAnchor.constraint(equalToConstant: Self.capsuleHeight),
            capsule.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            capsule.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),

            nameField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 9),
            nameField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -9),
            nameField.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        token = WAMacUI.observe { [weak self] in
            guard let self else { return }
            nameField.stringValue = model.state?.title ?? ""
            capsule.toolTip = model.subtitle.isEmpty ? nil : model.subtitle
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.avatarSize + Self.capsuleHeight - Self.overlap)
    }
}

private struct HeaderAvatar: View {
    let model: ChatHeaderModel

    var body: some View {
        if let state = model.state {
            AvatarView(state: state, size: ChatHeaderView.avatarSize)
        }
    }
}
