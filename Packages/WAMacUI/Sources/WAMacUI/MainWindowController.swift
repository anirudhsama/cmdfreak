import AppKit
import SwiftUI
import WAKit

@MainActor
public final class MainWindowController: NSWindowController {
    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "BetterWA"
        window.toolbarStyle = .unified
        window.contentView = NSHostingView(rootView: Text(WAKit.bridgeVersion()).padding(40))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
