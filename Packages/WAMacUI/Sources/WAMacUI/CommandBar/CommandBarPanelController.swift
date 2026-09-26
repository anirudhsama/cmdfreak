import AppKit
import SwiftUI
import WAKit

/// Hosts the command bar in a non-activating, borderless panel attached to the main window as a
/// child window, near its top edge. Keys are taken by a local monitor that is only installed
/// while the panel is shown and only acts while it is key. Losing key closes it.
@MainActor
final class CommandBarPanelController: NSObject, NSWindowDelegate {
    let model: CommandBarModel
    private let panel: CommandBarPanel
    private weak var owner: NSWindow?
    private var keyMonitor: Any?
    private var isHiding = false

    private static let topInset: CGFloat = 72

    init(model: CommandBarModel, owner: NSWindow) {
        self.model = model
        self.owner = owner
        panel = CommandBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: CommandBarMetrics.width, height: CommandBarMetrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]

        let hosting = NSHostingView(rootView: CommandBarView(model: model))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: CommandBarMetrics.width, height: CommandBarMetrics.height)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        model.onDismissRequest = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel.isVisible }
    var panelIsKey: Bool { panel.isKeyWindow }

    func show(scope: QuickSearchScope, context: CommandContext) {
        guard let owner else { return }
        model.present(scope: scope, context: context)
        guard !panel.isVisible else { return }
        if panel.parent !== owner {
            panel.parent?.removeChildWindow(panel)
            owner.addChildWindow(panel, ordered: .above)
        }
        position(over: owner)
        installKeyMonitor()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard !isHiding, panel.isVisible else { return }
        isHiding = true
        removeKeyMonitor()
        panel.orderOut(nil)
        panel.parent?.removeChildWindow(panel)
        if NSApp.isActive, owner?.isVisible == true { owner?.makeKey() }
        model.reset()
        isHiding = false
    }

    private func position(over owner: NSWindow) {
        let size = NSSize(width: CommandBarMetrics.width, height: CommandBarMetrics.height)
        let visible = (owner.screen ?? NSScreen.main)?.visibleFrame ?? owner.frame
        var x = owner.frame.midX - size.width / 2
        x = min(max(x, visible.minX + 12), visible.maxX - size.width - 12)
        var top = owner.frame.maxY - Self.topInset
        top = min(max(top, visible.minY + size.height + 12), visible.maxY - 12)
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: false)
    }

    // MARK: Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.panel.isKeyWindow else { return false }
                return self.handle(event)
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// ↑/↓, ⌃K/⌃J, ⌃P/⌃N move; Enter activates; Esc closes. Everything else goes to the field
    /// (and ⌘-shortcuts to the menu, so ⌘K toggles and ⌘N switches to contacts).
    private func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            return false
        }
        if mods.contains(.control) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "k", "p": model.moveSelection(by: -1); return true
            case "j", "n": model.moveSelection(by: 1); return true
            default: return false
            }
        }
        switch event.keyCode {
        case 126: model.moveSelection(by: -1); return true
        case 125: model.moveSelection(by: 1); return true
        case 36, 76:
            if model.activate() { hide() }
            return true
        case 53:
            hide()
            return true
        default:
            return false
        }
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

private final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

#if DEBUG
extension CommandBarPanelController {
    /// Runs the key monitor's handler directly (the self-test cannot make the panel key).
    func debugHandle(_ event: NSEvent) -> Bool { handle(event) }
}
#endif
