#if DEBUG
import AppKit
import SwiftUI

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
            .frame(width: RailMetrics.width, height: 200)
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
#endif
