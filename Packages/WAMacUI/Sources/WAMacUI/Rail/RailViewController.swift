import AppKit
import Observation
import SwiftUI
import WAKit

enum RailMetrics {
    static let width: CGFloat = 56
}

/// Rail model: the ordered items and the current selection. Tags append here later.
@MainActor @Observable
final class RailModel {
    /// Items in display order; `.archived` is rendered at the bottom.
    var items: [RailItem] = [.chats, .archived]
    var selection: RailItem = .chats

    var topItems: [RailItem] { items.filter { $0 != .archived } }
    var bottomItems: [RailItem] { items.filter { $0 == .archived } }

    /// ⌘⌥n addresses items by their 1-based display position.
    func item(at position: Int) -> RailItem? {
        let ordered = topItems + bottomItems
        guard position >= 1, position <= ordered.count else { return nil }
        return ordered[position - 1]
    }
}

@MainActor
final class RailViewController: NSViewController {
    let model: RailModel
    var onSelect: ((RailItem) -> Void)?

    init(model: RailModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let host = NSHostingView(rootView: RailView(model: model) { [weak self] item in self?.onSelect?(item) })
        host.sizingOptions = []
        view = host
    }
}

#if DEBUG
struct RailDebugView: View {
    let model: RailModel
    var body: some View { RailView(model: model) { _ in } }
}
#endif

private struct RailView: View {
    let model: RailModel
    let select: (RailItem) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(model.topItems, id: \.self) { item in
                RailButton(item: item, selected: model.selection == item) { select(item) }
            }
            Spacer(minLength: 0)
            ForEach(model.bottomItems, id: \.self) { item in
                RailButton(item: item, selected: model.selection == item) { select(item) }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(width: RailMetrics.width)
        .frame(maxHeight: .infinity)
    }
}

private struct RailButton: View {
    let item: RailItem
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: item.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 36, height: 30)
                    .foregroundStyle(selected ? .white : .secondary)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor)
                        }
                    }
                Text(item.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
            .frame(width: RailMetrics.width - 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension RailItem {
    var title: String {
        switch self {
        case .chats: "Chats"
        case .archived: "Archived"
        case .tag(_, let name): name
        }
    }

    var symbol: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right.fill"
        case .archived: "archivebox.fill"
        case .tag: "tag.fill"
        }
    }
}
