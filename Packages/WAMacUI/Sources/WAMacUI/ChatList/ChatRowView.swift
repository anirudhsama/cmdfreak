import SwiftUI

enum ChatRowMetrics {
    static let height: CGFloat = 72
    static let avatarSize: CGFloat = 48
    static let avatarSpacing: CGFloat = 12
    static let horizontalInset: CGFloat = 8
    static let contentPadding: CGFloat = 10
    static let selectionCornerRadius: CGFloat = 10
    /// Where the title column starts; separators are inset to line up with it.
    static let textLeading: CGFloat = horizontalInset + contentPadding + avatarSize + avatarSpacing
}

/// One chat row, laid out like WhatsApp for Mac: large avatar, name and time on the first line,
/// a one-line preview with pin, mute and unread accessories on the second, and a hairline
/// separator that starts at the text column. Reads only precomputed fields from `ChatRowState`.
struct ChatRowView: View {
    let state: ChatRowState
    let appearance: ChatListAppearance

    private var accessoryColor: Color { Color(nsColor: .tertiaryLabelColor) }

    var body: some View {
        HStack(spacing: ChatRowMetrics.avatarSpacing) {
            AvatarView(state: state)
                .frame(width: ChatRowMetrics.avatarSize, height: ChatRowMetrics.avatarSize)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(state.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(state.time)
                        .font(.system(size: 12))
                        .foregroundStyle(timeColor)
                        .monospacedDigit()
                }
                HStack(alignment: .center, spacing: 6) {
                    preview
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailingAccessories
                }
            }
        }
        .padding(.horizontal, ChatRowMetrics.contentPadding)
        .frame(height: ChatRowMetrics.height)
        .foregroundStyle(.primary)
        .background {
            // Gray, as in WhatsApp; a touch darker while the list has keyboard focus.
            if state.isSelected {
                RoundedRectangle(cornerRadius: ChatRowMetrics.selectionCornerRadius, style: .continuous)
                    .fill(appearance.isEmphasized ? Color.primary.opacity(0.11) : Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
            }
        }
        .overlay(alignment: .bottom) {
            if !state.isSelected {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1 / (NSScreen.main?.backingScaleFactor ?? 2))
                    .padding(.leading, ChatRowMetrics.textLeading - ChatRowMetrics.horizontalInset)
                    .padding(.trailing, ChatRowMetrics.contentPadding)
            }
        }
        .padding(.horizontal, ChatRowMetrics.horizontalInset)
        .contentShape(Rectangle())
    }

    private var timeColor: Color {
        state.unreadCount > 0 && !state.isMuted ? .waGreen : .secondary
    }

    @ViewBuilder
    private var preview: some View {
        if state.isTyping {
            Text("typing…")
                .foregroundStyle(Color.waGreen)
        } else {
            previewText
                .foregroundStyle(.secondary)
        }
    }

    private var previewText: Text {
        let prefix = state.previewPrefix.map { Text($0 + ": ") } ?? Text("")
        let symbol = state.previewSymbol.map { Text("\(Image(systemName: $0)) ") } ?? Text("")
        return Text("\(prefix)\(symbol)\(state.previewText)")
    }

    @ViewBuilder
    private var trailingAccessories: some View {
        HStack(spacing: 6) {
            if state.isMuted {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(accessoryColor)
            }
            if state.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .rotationEffect(.degrees(45))
                    .foregroundStyle(accessoryColor)
            }
            if state.unreadCount > 0 {
                Text(state.unreadCount > 999 ? "999+" : String(state.unreadCount))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.waOnBadge)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Capsule().fill(badgeColor))
            } else if state.markedUnread {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 12, height: 12)
                    .padding(4)
            }
        }
    }

    private var badgeColor: Color {
        state.isMuted ? Color(nsColor: .tertiaryLabelColor) : .waBadge
    }
}

/// Cached avatar image, or initials on a stable per-chat tint.
struct AvatarView: View {
    let state: ChatRowState
    /// Diameter the caller frames it at; glyphs and initials scale with it.
    var size: CGFloat = ChatRowMetrics.avatarSize

    var body: some View {
        if let avatar = state.avatar {
            Image(decorative: avatar, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(Circle())
        } else if state.isGroup {
            Circle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: size * 0.375))
                        .foregroundStyle(.secondary)
                }
        } else {
            Circle()
                .fill(AvatarTint.color(for: state.jid).gradient)
                .overlay {
                    if state.initials.isEmpty {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.46))
                            .foregroundStyle(.white)
                    } else {
                        Text(state.initials)
                            .font(.system(size: size * 0.375, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
        }
    }
}

enum AvatarTint {
    private static let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .cyan, .mint, .brown, .red]

    static func color(for jid: String) -> Color {
        var hash: UInt32 = 2166136261
        for byte in jid.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        return palette[Int(hash % UInt32(palette.count))]
    }
}
