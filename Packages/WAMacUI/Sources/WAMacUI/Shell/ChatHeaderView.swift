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

struct ChatHeaderView: View {
    static let avatarSize: CGFloat = 30
    static let capsuleHeight: CGFloat = 24
    /// Capsule tucks this far under the avatar.
    static let overlap: CGFloat = 5

    let model: ChatHeaderModel

    var body: some View {
        if let state = model.state {
            VStack(spacing: -Self.overlap) {
                AvatarView(state: state, size: Self.avatarSize)
                    .frame(width: Self.avatarSize, height: Self.avatarSize)
                    .zIndex(1)
                Text(state.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 11)
                    .frame(height: Self.capsuleHeight)
                    .frame(maxWidth: 320)
                    .fixedSize()
                    .glassEffect(.regular, in: .capsule)
                    .help(model.subtitle)
            }
        }
    }
}
