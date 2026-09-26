import AppKit
import SwiftUI
import WAKit

@MainActor
public final class OnboardingWindowController: NSWindowController {
    public let model: OnboardingModel

    public init(model: OnboardingModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Link BetterWA"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")
        window.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: OnboardingView(model: model))
        host.sizingOptions = []
        window.contentView = host
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
