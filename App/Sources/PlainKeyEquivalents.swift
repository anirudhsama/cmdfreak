import AppKit

/// Menu items whose shortcut has no modifier (Esc, Space). AppKit lets a matching menu item claim
/// a key even while disabled, which would swallow every Space typed into compose. These items are
/// armed only while their action is live: a local key monitor re-validates them just before each
/// unmodified key is dispatched, and the full shortcut is restored for display when the menu opens.
@MainActor
final class PlainKeyEquivalents: NSObject, NSMenuDelegate {
    static let shared = PlainKeyEquivalents()

    private var items: [(item: NSMenuItem, key: String)] = []
    private var monitor: Any?

    func manage(_ newItems: [NSMenuItem], in menu: NSMenu) {
        items += newItems.map { ($0, $0.keyEquivalent) }
        menu.delegate = self
        refresh()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
                MainActor.assumeIsolated { PlainKeyEquivalents.shared.refresh() }
            }
            return event
        }
    }

    /// Arms each item only if its action currently has a target that validates it.
    func refresh() {
        for (item, key) in items {
            let live = isLive(item)
            if item.keyEquivalent != (live ? key : "") { item.keyEquivalent = live ? key : "" }
        }
    }

    private func isLive(_ item: NSMenuItem) -> Bool {
        guard let action = item.action,
              let target = item.target ?? NSApp.target(forAction: action, to: nil, from: item) else { return false }
        return (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
    }

    func menuWillOpen(_ menu: NSMenu) {
        for (item, key) in items where item.menu === menu { item.keyEquivalent = key }
    }

    func menuDidClose(_ menu: NSMenu) {
        refresh()
    }
}
