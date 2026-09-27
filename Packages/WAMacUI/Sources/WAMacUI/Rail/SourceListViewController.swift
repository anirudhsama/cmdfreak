import AppKit
import Observation
import SwiftUI
import WAKit

enum SourceListMetrics {
    static let minWidth: CGFloat = 180
    static let idealWidth: CGFloat = 220
    static let maxWidth: CGFloat = 320
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

    init(model: RailModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let host = NSHostingView(rootView: SourceListView(model: model) { [weak self] item in self?.onSelect?(item) })
        host.sizingOptions = []
        view = host
    }
}

#if DEBUG
struct RailDebugView: View {
    let model: RailModel
    var body: some View { SourceListView(model: model) { _ in }.frame(width: SourceListMetrics.idealWidth, height: 400) }
}
#endif

private struct SourceListView: View {
    let model: RailModel
    let select: (RailItem) -> Void

    var body: some View {
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
