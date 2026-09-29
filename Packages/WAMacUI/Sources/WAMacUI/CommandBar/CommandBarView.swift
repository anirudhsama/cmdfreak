import SwiftUI
import WAKit

enum CommandBarMetrics {
    static let width: CGFloat = 620
    static let height: CGFloat = 440
    static let cornerRadius: CGFloat = 22
    static let rowHeight: CGFloat = 48
    static let avatarSize: CGFloat = 30
}

/// The command bar's content: search field, results, and a key-hint footer, on one glass surface.
struct CommandBarView: View {
    @Bindable var model: CommandBarModel
    /// Glass does not render in offscreen snapshots; debug renders substitute a material.
    var useGlass = true
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.6)
            results
            Divider().opacity(0.6)
            footer
        }
        .frame(width: CommandBarMetrics.width, height: CommandBarMetrics.height)
        .modifier(CommandBarSurface(useGlass: useGlass))
        .onChange(of: model.focusRequest, initial: true) { fieldFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: model.scope == .contacts ? "person.crop.circle.badge.plus" : "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            if model.scope == .contacts {
                Text("New Chat")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
            }
            if useGlass {
                TextField(model.placeholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($fieldFocused)
            } else {
                // Offscreen renders cannot draw AppKit-backed controls.
                Text(model.query.isEmpty ? model.placeholder : model.query)
                    .font(.system(size: 20))
                    .foregroundStyle(model.query.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    @ViewBuilder
    private var results: some View {
        if model.results.isEmpty {
            VStack(spacing: 6) {
                if model.hasLoaded {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(model.query.isEmpty ? "No chats yet" : "No Results")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !useGlass {
            VStack(spacing: 2) {
                ForEach(Array(model.results.prefix(6).enumerated()), id: \.element.id) { index, result in
                    CommandBarRow(result: result, isSelected: index == model.selectedIndex)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                            CommandBarRow(result: result, isSelected: index == model.selectedIndex)
                                .id(result.id)
                                .contentShape(Rectangle())
                                .onTapGesture { if model.activate(at: index) { model.onDismissRequest?() } }
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.automatic)
                .onChange(of: model.selectedIndex) { _, index in
                    guard model.results.indices.contains(index) else { return }
                    proxy.scrollTo(model.results[index].id)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Spacer()
            KeyHint(keys: "↩", label: actionLabel)
            KeyHint(keys: "↑↓", label: "Navigate")
            KeyHint(keys: "esc", label: "Close")
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private var actionLabel: String {
        switch model.selected {
        case .chat(let r) where !r.candidate.hasChat: "Start Chat"
        case .chat: "Open Chat"
        case .action: "Run"
        case nil: "Open"
        }
    }
}

private struct CommandBarSurface: ViewModifier {
    let useGlass: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CommandBarMetrics.cornerRadius, style: .continuous)
        if useGlass {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape).clipShape(shape)
        }
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 18)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary))
            Text(label).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}

struct CommandBarRow: View {
    let result: CommandBarResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            leading
                .frame(width: CommandBarMetrics.avatarSize, height: CommandBarMetrics.avatarSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: CommandBarMetrics.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.waGreen)
            }
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch result {
        case .chat(let r):
            CommandBarAvatar(candidate: r.candidate)
        case .action(let a):
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.white.opacity(0.22)) : AnyShapeStyle(.quaternary))
                .overlay {
                    Image(systemName: a.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                }
        }
    }

    private var title: String {
        switch result {
        case .chat(let r): r.candidate.title
        case .action(let a): a.title
        }
    }

    private var subtitle: String {
        switch result {
        case .chat(let r):
            let c = r.candidate
            let phone = c.phone.flatMap { $0.isEmpty ? nil : "+" + $0 }
            switch c.kind {
            case .group: return "Group"
            case .broadcast: return "Broadcast list"
            default:
                if !c.hasChat { return [phone, "New chat"].compactMap { $0 }.joined(separator: " · ") }
                if let phone, phone != c.title { return phone }
                return c.alternateNames.first ?? "Chat"
            }
        case .action:
            return "Action"
        }
    }

    private var trailing: String? {
        switch result {
        case .chat(let r): r.candidate.archived ? "Archived" : nil
        case .action(let a): a.shortcut
        }
    }
}

/// Cached avatar when one is on disk; initials on the chat's tint otherwise (same as the list).
private struct CommandBarAvatar: View {
    let candidate: QuickSearchCandidate
    @State private var image: CGImage?

    private static var pixelSize: Int { Int(CommandBarMetrics.avatarSize) * 2 }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill).clipShape(Circle())
            } else if candidate.kind == .group {
                Circle().fill(.quaternary).overlay {
                    Image(systemName: "person.2.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Circle().fill(AvatarTint.color(for: candidate.jid)).overlay {
                    if Initials.from(candidate.title).isEmpty {
                        Image(systemName: "person.fill").font(.system(size: 14)).foregroundStyle(.white)
                    } else {
                        Text(Initials.from(candidate.title)).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    }
                }
            }
        }
        .task(id: candidate.avatarURL) {
            guard let url = candidate.avatarURL, let key = ThumbnailCache.fileKey(url) else { image = nil; return }
            if let hit = ThumbnailCache.shared.cached(key: key, maxPixelSize: Self.pixelSize) {
                image = hit
                return
            }
            image = await ThumbnailCache.shared.image(key: key, source: .file(url), maxPixelSize: Self.pixelSize)
        }
    }
}
