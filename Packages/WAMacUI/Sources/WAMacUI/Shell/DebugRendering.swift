#if DEBUG
import AppKit
import SwiftUI
import WAKit

extension MainWindowController {
    /// Offscreen renders of the rail and the first rows, for verification without screen capture.
    public func debugRenderPieces() -> [(String, CGImage?)] {
        var out: [(String, CGImage?)] = []
        let states = chatList.debugStates(limit: 12)
        let emphasized = ChatListAppearance()
        emphasized.isEmphasized = true
        for (name, appearance) in [("rows", chatList.appearance), ("rows-emphasized", emphasized)] {
            let list = VStack(spacing: 0) {
                ForEach(states, id: \.jid) { ChatRowView(state: $0, appearance: appearance) }
            }
            .frame(width: 300)
            .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: list)
            renderer.scale = 2
            out.append((name, renderer.cgImage))
        }
        let rail = ImageRenderer(content: RailDebugView(model: railModel)
            .background(Color(nsColor: .windowBackgroundColor)))
        rail.scale = 2
        out.append(("rail", rail.cgImage))
        return out
    }
}

extension ChatListViewController {
    func debugStates(limit: Int) -> [ChatRowState] {
        items.prefix(limit).compactMap { rowState(for: $0.id) }
    }
}

public struct CommandBarDebugState: Sendable {
    public var visible: Bool
    public var isKey: Bool
    public var contactsScope: Bool
    public var query: String
    public var results: [String]
    public var selectedIndex: Int
}

extension MainWindowController {
    public var debugCommandBar: CommandBarDebugState {
        let model = commandBar.model
        let titles = model.results.map { result -> String in
            switch result {
            case .chat(let r): "\(r.candidate.title) [\(r.candidate.hasChat ? "chat" : "contact")]"
            case .action(let a): "\(a.title) [action]"
            }
        }
        return CommandBarDebugState(visible: commandBar.isVisible, isKey: commandBar.panelIsKey, contactsScope: model.scope == .contacts,
                                    query: model.query, results: titles, selectedIndex: model.selectedIndex)
    }

    @discardableResult
    public func debugCommandBarKey(_ event: NSEvent) -> Bool { commandBar.debugHandle(event) }

    public func debugSetCommandBarQuery(_ query: String) { commandBar.model.query = query }

    public var debugFirstResponder: String {
        window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
    }

    public func debugListRefusesFocus() -> Bool { chatList.debugRefusesFocus }
    public func debugClickRow(at index: Int) { chatList.debugClick(row: index) }
    public func debugCommandClickSelectedRow() {
        guard let jid = chatList.selectedJid, let index = chatList.items.firstIndex(where: { $0.id == jid }) else { return }
        chatList.debugClick(row: index, modifiers: .command)
    }
    public var debugSearchIsEditing: Bool { chatListColumn.searchBar.isEditing }

    public var debugRailIsArchived: Bool { railModel.selection == .archived }
    public var debugRailTitle: String { railModel.selection.title }
    /// Sidebar and chat-list widths.
    public var debugSplitWidths: [CGFloat] { [split.sidebarWidth, split.listWidth] }
    public func debugToggleSidebar() { split.toggleSidebar(nil) }

    public func debugChat(_ jid: String) -> ChatRecord? {
        chatList.items.first { $0.id == jid }?.chat
    }

    public func chatTitle(_ jid: String) -> String? {
        chatList.items.first { $0.id == jid }?.title
    }

    public func chatShowsUnread(_ jid: String) -> Bool {
        chatList.items.first { $0.id == jid }?.showsUnread ?? false
    }

    public func debugPinnedJids() -> [String] {
        chatList.items.filter { $0.chat.isPinned }.map(\.id)
    }

    /// Renders the command bar's SwiftUI content with its current model (a material stands in for
    /// glass, which does not composite offscreen).
    public func debugRenderCommandBar(dark: Bool = false) -> CGImage? {
        let view = CommandBarView(model: commandBar.model, useGlass: false)
            .environment(\.colorScheme, dark ? .dark : .light)
            .padding(24)
            .background(Color(nsColor: dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.92, alpha: 1)))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage
    }
}
#endif
