import SwiftUI

enum ChatRowMetrics {
    static let height: CGFloat = 64
    static let avatarSize: CGFloat = 40
    static let horizontalInset: CGFloat = 8
    static let selectionCornerRadius: CGFloat = 8
}

/// One chat row. Reads only precomputed fields from `ChatRowState`.
struct ChatRowView: View {
    let state: ChatRowState
    let appearance: ChatListAppearance

    private var emphasized: Bool { state.isSelected && appearance.isEmphasized }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(state: state)
                .frame(width: ChatRowMetrics.avatarSize, height: ChatRowMetrics.avatarSize)

            // Top-aligned at a fixed offset so one- and two-line previews keep titles level.
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(state.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if state.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(emphasized ? Color.white.opacity(0.8) : Color(nsColor: .tertiaryLabelColor))
                    }
                    Spacer(minLength: 6)
                    Text(state.time)
                        .font(.system(size: 11))
                        .foregroundStyle(emphasized ? .white.opacity(0.85) : (state.showsUnread ? .primary : .secondary))
                        .monospacedDigit()
                }
                HStack(alignment: .top, spacing: 6) {
                    preview
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailingAccessories
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 11)
        }
        .padding(.horizontal, 10)
        .frame(height: ChatRowMetrics.height)
        .foregroundStyle(emphasized ? .white : .primary)
        .background {
            if state.isSelected {
                RoundedRectangle(cornerRadius: ChatRowMetrics.selectionCornerRadius, style: .continuous)
                    .fill(appearance.isEmphasized ? Color.accentColor : Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
            }
        }
        .padding(.horizontal, ChatRowMetrics.horizontalInset)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var preview: some View {
        if state.isTyping {
            Text("typing…")
                .italic()
                .foregroundStyle(emphasized ? .white : Color(nsColor: .systemGreen))
        } else {
            previewText
                .foregroundStyle(emphasized ? .white.opacity(0.9) : .secondary)
        }
    }

    private var previewText: Text {
        let prefix = state.previewPrefix.map { Text($0 + ": ") } ?? Text("")
        let symbol = state.previewSymbol.map { Text("\(Image(systemName: $0)) ") } ?? Text("")
        return Text("\(prefix)\(symbol)\(state.previewText)")
    }

    @ViewBuilder
    private var trailingAccessories: some View {
        HStack(spacing: 4) {
            if state.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(emphasized ? Color.white.opacity(0.8) : Color(nsColor: .tertiaryLabelColor))
            }
            if state.unreadCount > 0 {
                Text(state.unreadCount > 999 ? "999+" : String(state.unreadCount))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(emphasized ? Color.accentColor : .white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(emphasized ? Color.white : Color(nsColor: .systemGreen)))
            } else if state.markedUnread {
                Circle()
                    .fill(emphasized ? Color.white : Color(nsColor: .systemGreen))
                    .frame(width: 9, height: 9)
                    .padding(.vertical, 4)
            }
        }
        .padding(.top, 1)
    }
}

/// Cached avatar image, or initials on a stable per-chat tint.
struct AvatarView: View {
    let state: ChatRowState

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
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
        } else {
            Circle()
                .fill(AvatarTint.color(for: state.jid).gradient)
                .overlay {
                    if state.initials.isEmpty {
                        Image(systemName: "person.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                    } else {
                        Text(state.initials)
                            .font(.system(size: 15, weight: .medium))
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
