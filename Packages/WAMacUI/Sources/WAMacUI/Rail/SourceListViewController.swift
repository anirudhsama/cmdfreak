import AppKit
import Observation
import SwiftUI
import WAKit

enum SourceListMetrics {
    /// Collapsed: an icon rail just wide enough for the traffic lights.
    /// With the unified toolbar the traffic lights span 19–79pt; 97pt (plus the 1pt divider)
    /// leaves the same 19pt on both sides.
    static let railWidth: CGFloat = 97
    /// Expanded widths. Anything between the rail and `minWidth` snaps to one of them.
    static let minWidth: CGFloat = 180
    static let idealWidth: CGFloat = 220
    static let maxWidth: CGFloat = 320
    /// Below this width the sidebar renders as the rail.
    static let railThreshold: CGFloat = 130
}

/// Sidebar model: the ordered filters and the current selection. Tags append here later.
@MainActor @Observable
final class RailModel {
    var items: [RailItem] = [.chats, .unread, .groups, .archived]
    var selection: RailItem = .chats
    var counts = SidebarCounts()

    var filterItems: [RailItem] { items.filter { if case .tag = $0 { false } else { true } } }
    var tagItems: [RailItem] { items.filter { if case .tag = $0 { true } else { false } } }

    /// ⌥⌘n addresses items by their 1-based display position.
    func item(at position: Int) -> RailItem? {
        let ordered = filterItems + tagItems
        guard position >= 1, position <= ordered.count else { return nil }
        return ordered[position - 1]
    }

    func badge(for item: RailItem) -> Int {
        switch item {
        case .chats, .unread: counts.chats
        case .groups: counts.groups
        case .archived: counts.archived
        case .tag: 0
        }
    }
}

/// The window's sidebar: a Mail-style source list of chat filters, drawn by the system as the
/// floating glass sidebar.
@MainActor
final class SourceListViewController: NSViewController {
    let model: RailModel
    var onSelect: ((RailItem) -> Void)?
    var onToggle: (() -> Void)?

    init(model: RailModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let host = NSHostingView(rootView: SourceListView(
            model: model,
            select: { [weak self] item in self?.onSelect?(item) },
            toggle: { [weak self] in self?.onToggle?() }
        ))
        host.sizingOptions = []
        view = host
    }
}

#if DEBUG
struct RailDebugView: View {
    let model: RailModel
    var body: some View { SourceListView(model: model, select: { _ in }, toggle: {}).frame(width: SourceListMetrics.idealWidth, height: 400) }
}
#endif

/// Renders as a labelled source list when wide, and as an icon rail when collapsed to
/// `SourceListMetrics.railWidth`.
private struct SourceListView: View {
    let model: RailModel
    let select: (RailItem) -> Void
    let toggle: () -> Void

    var body: some View {
        GeometryReader { geo in
            let isRail = geo.size.width < SourceListMetrics.railThreshold
            VStack(spacing: 0) {
                if isRail { rail } else { list }
                toggleButton(isRail: isRail)
            }
        }
    }

    private var list: some View {
        List(selection: Binding(get: { model.selection }, set: { if let item = $0 { select(item) } })) {
            Section {
                ForEach(model.filterItems, id: \.self) { row($0) }
            }
            if !model.tagItems.isEmpty {
                Section("Tags") {
                    ForEach(model.tagItems, id: \.self) { row($0) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ item: RailItem) -> some View {
        Label(item.title, systemImage: item.symbol)
            .badge(model.badge(for: item))
            .tag(item)
    }

    private var rail: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                ForEach(model.filterItems + model.tagItems, id: \.self) { item in
                    // Unread's count equals Chats'; one badge is enough in the compact rail.
                    RailIcon(item: item, selected: model.selection == item, badge: item == .unread ? 0 : model.badge(for: item)) { select(item) }
                }
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }

    private func toggleButton(isRail: Bool) -> some View {
        Button(action: toggle) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isRail ? "Expand Sidebar (⌃⌘S)" : "Collapse Sidebar (⌃⌘S)")
        .frame(maxWidth: .infinity, alignment: isRail ? .center : .leading)
        .padding(.horizontal, isRail ? 0 : 12)
        .padding(.bottom, 12)
    }
}

private struct RailIcon: View {
    let item: RailItem
    let selected: Bool
    let badge: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: item.symbol)
                .font(.system(size: 18, weight: .medium))
                .symbolVariant(selected ? .fill : .none)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 44, height: 40)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.16) : (hovering ? Color.primary.opacity(0.06) : .clear))
                }
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 4, y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension RailItem {
    var title: String {
        switch self {
        case .chats: "Chats"
        case .unread: "Unread"
        case .groups: "Groups"
        case .archived: "Archived"
        case .tag(_, let name): name
        }
    }

    var symbol: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right"
        case .unread: "message.badge"
        case .groups: "person.2"
        case .archived: "archivebox"
        case .tag: "tag"
        }
    }
}
