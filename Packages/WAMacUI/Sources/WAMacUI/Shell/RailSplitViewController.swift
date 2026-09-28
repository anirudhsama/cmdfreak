import AppKit

/// Split view whose sidebar never disappears: collapsing shrinks it to the icon rail (just wide
/// enough for the traffic lights), and the divider snaps between the rail and the expanded widths.
@MainActor
final class RailSplitViewController: NSSplitViewController {
    /// Width to return to when expanding from the rail.
    private var lastExpandedWidth = SourceListMetrics.idealWidth
    private var animation: Timer?

    var sidebarWidth: CGFloat { splitViewItems.first?.viewController.view.frame.width ?? 0 }
    var isRail: Bool { sidebarWidth < SourceListMetrics.railThreshold }

    /// A restored divider position can leave the collapsed sidebar at an old rail width; the rail
    /// is always exactly `railWidth`.
    func normalizeRailWidth() {
        if isRail, abs(sidebarWidth - SourceListMetrics.railWidth) > 0.5, animation == nil {
            moveDivider(to: SourceListMetrics.railWidth)
        }
    }

    /// Divider drags snap to the rail or to at least the expanded minimum width.
    override func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // NSSplitViewController doesn't implement this delegate method; calling super raises.
        let position = proposedPosition
        // Snapping is for drags; the toggle animation passes through the in-between widths.
        guard dividerIndex == 0, animation == nil else { return position }
        // Snap: the middle of the gap between rail and expanded widths decides which side wins.
        let midpoint = (SourceListMetrics.railWidth + SourceListMetrics.minWidth) / 2
        if position < midpoint { return SourceListMetrics.railWidth }
        return max(position, SourceListMetrics.minWidth)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        if !isRail, animation == nil { lastExpandedWidth = sidebarWidth }
    }

    /// ⌃⌘S and the sidebar's own button: rail ⇄ expanded instead of hiding the sidebar.
    override func toggleSidebar(_ sender: Any?) {
        setSidebar(width: isRail ? lastExpandedWidth : SourceListMetrics.railWidth, animated: true)
    }

    /// The sidebar item cannot collapse, which makes AppKit disable Toggle Sidebar; here it always
    /// switches between rail and expanded.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)) {
            (item as? NSMenuItem)?.title = isRail ? "Expand Sidebar" : "Collapse Sidebar"
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    func setSidebar(width target: CGFloat, animated: Bool) {
        animation?.invalidate()
        animation = nil
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            moveDivider(to: target)
            return
        }
        let start = sidebarWidth
        let began = CACurrentMediaTime()
        let duration = 0.2
        // Divider positions are not animatable through the animator proxy; step it per frame.
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step(from: start, to: target, began: began, duration: duration) }
        }
    }

    private func step(from start: CGFloat, to target: CGFloat, began: CFTimeInterval, duration: CFTimeInterval) {
        let t = min(1, (CACurrentMediaTime() - began) / duration)
        let eased = 1 - pow(1 - t, 3)
        moveDivider(to: start + (target - start) * eased)
        if t >= 1 {
            animation?.invalidate()
            animation = nil
        }
    }

    private func moveDivider(to width: CGFloat) {
        // Keep the chat list's width; the conversation absorbs the change.
        let listWidth = splitViewItems.count > 1 ? splitViewItems[1].viewController.view.frame.width : 0
        splitView.setPosition(width, ofDividerAt: 0)
        if splitViewItems.count > 2 {
            splitView.setPosition(width + splitView.dividerThickness + listWidth, ofDividerAt: 1)
        }
    }
}

