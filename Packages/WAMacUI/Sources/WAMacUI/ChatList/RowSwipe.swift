import AppKit
import QuartzCore

/// The side of a row a swipe uncovers: `.leading` when the row moves right.
enum SwipeEdge {
    case leading, trailing
}

/// An action uncovered by swiping a row: a white icon on a colored circle.
struct SwipeAction {
    let title: String
    let symbol: String
    let color: NSColor
    /// The row leaves the list (archive, unarchive), so it slides out before the action runs.
    var removesRow = false
    let perform: @MainActor () -> Void
}

enum SwipeMetrics {
    static let buttonSize: CGFloat = 46
    /// Between buttons.
    static let spacing: CGFloat = 10
    /// Between the nearest button and the moved cell; the row's own inset makes up the rest of
    /// `spacing` to its highlight.
    static let rowGap: CGFloat = spacing - ChatRowMetrics.horizontalInset
    /// Between the outermost button and the list edge; the row's own inset.
    static let edgeInset: CGFloat = ChatRowMetrics.horizontalInset

    /// How far the row moves to show `count` buttons at full size.
    static func openWidth(count: Int) -> CGFloat {
        edgeInset + CGFloat(count) * (buttonSize + spacing) - spacing + rowGap
    }

    /// How far the row moves before releasing runs the outermost action.
    static func fullSwipeWidth(count: Int, rowWidth: CGFloat) -> CGFloat {
        max(openWidth(count: count) + 48, rowWidth * 0.55)
    }
}

/// One button's place in the space a swipe uncovers, measured from the list edge. Like Messages:
/// each button grows from the center of its final spot, appearing once the row has moved past that
/// spot and keeping a gap to the row, so it is full size at the open width. The outermost comes
/// first; past the open width it stretches into a capsule while the others stay beside the row,
/// dimming once a full swipe is armed.
struct SwipeButtonLayout: Equatable {
    /// Distance from the list edge to the button's outer side.
    var inset: CGFloat
    var length: CGFloat
    var diameter: CGFloat
    var opacity: CGFloat

    /// Layouts for `count` buttons, outermost first, with the row moved `revealed` points.
    /// `armed` runs from 0 to 1 as a full swipe arms.
    static func layouts(revealed: CGFloat, count: Int, armed: CGFloat) -> [SwipeButtonLayout] {
        let size = SwipeMetrics.buttonSize, gap = SwipeMetrics.spacing, rowGap = SwipeMetrics.rowGap
        let open = SwipeMetrics.openWidth(count: count)
        return (0..<count).map { i in
            if revealed <= open {
                let center = SwipeMetrics.edgeInset + CGFloat(i) * (size + gap) + size / 2
                let radius = min(size / 2, max(0, revealed - rowGap - center))
                let opacity = min(1, max(0, (2 * radius - 4) / (size * 0.5)))
                return SwipeButtonLayout(inset: center - radius, length: 2 * radius, diameter: 2 * radius, opacity: opacity)
            }
            let rowSide = revealed - rowGap - CGFloat(count - 1 - i) * (size + gap)
            if i == 0 {
                return SwipeButtonLayout(inset: SwipeMetrics.edgeInset, length: rowSide - SwipeMetrics.edgeInset, diameter: size, opacity: 1)
            }
            return SwipeButtonLayout(inset: rowSide - size, length: size, diameter: size, opacity: 1 - 0.6 * armed)
        }
    }
}

/// A swipe action's button: a colored circle, or capsule once stretched, with a white icon.
@MainActor
final class SwipeActionButton: NSView {
    var onPress: (() -> Void)?
    private let body = NSView()
    private let icon = NSImageView()
    private var color: NSColor = .systemBlue

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        body.wantsLayer = true
        body.layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .white
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        body.addSubview(icon)
        addSubview(body)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ action: SwipeAction) {
        color = action.color
        body.layer?.backgroundColor = color.cgColor
        icon.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        setAccessibilityLabel(action.title)
    }

    /// Lays out the body to fill the button, fading it by `opacity`. `iconShift` (0 to 1) moves the
    /// icon from the middle to the row's side, which is the trailing side when `rowSideIsMaxX`.
    func layout(opacity: CGFloat, iconShift: CGFloat, rowSideIsMaxX: Bool) {
        body.frame = bounds
        body.alphaValue = opacity
        body.layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        let side = min(bounds.height * 0.48, 22)
        let rest = (bounds.width - side) / 2
        let rowSide = rowSideIsMaxX ? bounds.width - bounds.height / 2 - side / 2 : bounds.height / 2 - side / 2
        icon.frame = NSRect(x: rest + (rowSide - rest) * iconShift, y: (bounds.height - side) / 2, width: side, height: side)
    }

    // Gets the click instead of the table selecting the row.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        body.alphaValue > 0.5 ? super.hitTest(point).map { _ in self } : nil
    }

    override func mouseDown(with event: NSEvent) { setPressed(true) }

    override func mouseDragged(with event: NSEvent) { setPressed(contains(event)) }

    override func mouseUp(with event: NSEvent) {
        setPressed(false)
        if contains(event) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    private func contains(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }

    private func setPressed(_ pressed: Bool) {
        body.layer?.backgroundColor = (pressed ? color.blended(withFraction: 0.2, of: .black) ?? color : color).cgColor
    }
}

/// Two-finger horizontal swipes on the chat list's rows, after Messages: the row follows the
/// fingers, releasing past half the open width leaves it open, and a full swipe runs the outermost
/// action. Vertical gestures and mouse wheels go on to the scroll view.
@MainActor
final class RowSwipeController: NSObject {
    /// The actions for a row's edge, outermost first; none turns that edge off.
    var actions: (_ row: Int, _ edge: SwipeEdge) -> [SwipeAction] = { _, _ in [] }

    /// A row is swiped open or opening, so a click should close it rather than select.
    var isOpen: Bool {
        reconcile()
        return session.map { !$0.committed } ?? false
    }

    private weak var tableView: NSTableView?
    private var session: Session?
    private var gesture: Gesture = .idle
    /// A horizontal swipe's momentum coasts on after the fingers lift; it must not scroll the list.
    private var swallowsMomentum = false
    private var link: CADisplayLink?

    private enum Gesture {
        case idle
        /// Too little movement to tell the direction; the events wait here.
        case pending([NSEvent], dx: CGFloat, dy: CGFloat)
        case horizontal
        case vertical
    }

    @MainActor private final class Session {
        let cell: ChatRowCell
        let state: ChatRowState
        let leading: [SwipeAction]
        let trailing: [SwipeAction]
        var edge: SwipeEdge?
        /// Finger travel; `offset` is this after resistance.
        var finger: CGFloat = 0
        var offset: CGFloat = 0
        /// Points per second, in `offset`.
        var velocity: CGFloat = 0
        var lastEventTime: TimeInterval = 0
        var target: CGFloat?
        var onArrival: (() -> Void)?
        var armed = false
        var armProgress: CGFloat = 0
        /// An action has run; the row is only animating now.
        var committed = false

        init(cell: ChatRowCell, state: ChatRowState, leading: [SwipeAction], trailing: [SwipeAction]) {
            self.cell = cell
            self.state = state
            self.leading = leading
            self.trailing = trailing
        }

        var shown: [SwipeAction] { edge == .leading ? leading : edge == .trailing ? trailing : [] }
        var isValid: Bool { cell.state === state }
    }

    init(tableView: NSTableView) {
        self.tableView = tableView
    }

    // MARK: Events

    func scrollWheel(_ event: NSEvent, forward: (NSEvent) -> Void) {
        guard event.hasPreciseScrollingDeltas else {
            close()
            forward(event)
            return
        }
        if event.phase.isEmpty {
            if swallowsMomentum {
                if event.momentumPhase == .ended { swallowsMomentum = false }
            } else {
                forward(event)
            }
            return
        }
        // Finger travel: with natural scrolling the deltas already follow the fingers.
        let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        switch event.phase {
        case .began:
            swallowsMomentum = false
            gesture = .pending([], dx: 0, dy: 0)
            fallthrough
        case .changed:
            switch gesture {
            case .pending(let held, let x, let y):
                resolve(held + [event], dx: x + dx, dy: y + event.scrollingDeltaY, forward: forward)
            case .horizontal:
                track(dx, at: event.timestamp)
            case .vertical, .idle:
                forward(event)
            }
        case .ended, .cancelled:
            switch gesture {
            case .horizontal:
                if event.phase == .cancelled {
                    // The system took the gesture over: settle closed, run nothing.
                    session?.armed = false
                    animate(to: 0)
                } else {
                    release()
                }
                swallowsMomentum = true
            case .pending(let held, _, _):
                held.forEach(forward)
                forward(event)
            case .vertical, .idle:
                forward(event)
            }
            gesture = .idle
        default:
            if case .horizontal = gesture { return }
            forward(event)
        }
    }

    /// Settles the gesture's direction once it has moved a few points.
    private func resolve(_ held: [NSEvent], dx: CGFloat, dy: CGFloat, forward: (NSEvent) -> Void) {
        guard abs(dx) + abs(dy) >= 4 else {
            gesture = .pending(held, dx: dx, dy: dy)
            return
        }
        if abs(dx) > abs(dy), let first = held.first, startSession(at: first.locationInWindow) {
            gesture = .horizontal
            track(dx, at: held.last?.timestamp ?? first.timestamp)
        } else {
            gesture = .vertical
            close()
            held.forEach(forward)
        }
    }

    private func startSession(at windowPoint: NSPoint) -> Bool {
        guard let tableView else { return false }
        let row = tableView.row(at: tableView.convert(windowPoint, from: nil))
        guard row >= 0, let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ChatRowCell,
              let state = cell.state else { return false }
        if let session, session.cell === cell, session.isValid {
            // Catch the row mid-animation or open.
            session.target = nil
            session.onArrival = nil
            session.finger = session.offset
            session.velocity = 0
            return true
        }
        if let session {
            session.cell.resetSwipe(animated: true)
            self.session = nil
        }
        let next = Session(cell: cell, state: state, leading: actions(row, .leading), trailing: actions(row, .trailing))
        guard !next.leading.isEmpty || !next.trailing.isEmpty else { return false }
        session = next
        return true
    }

    private func track(_ dx: CGFloat, at time: TimeInterval) {
        guard let session, session.isValid else { return end() }
        session.finger += dx
        let width = session.cell.bounds.width
        let limit = { (actions: [SwipeAction]) in actions.isEmpty ? 0 : width - SwipeMetrics.edgeInset }
        let previous = session.offset
        session.offset = session.finger >= 0
            ? Self.resist(session.finger, limit: limit(session.leading))
            : -Self.resist(-session.finger, limit: limit(session.trailing))
        let dt = max(time - session.lastEventTime, 1.0 / 120)
        let instant = (session.offset - previous) / dt
        session.velocity = session.lastEventTime == 0 ? instant : session.velocity * 0.6 + instant * 0.4
        session.lastEventTime = time
        apply(session)
    }

    /// Travel past `limit` moves the row a fifth as far.
    private static func resist(_ travel: CGFloat, limit: CGFloat) -> CGFloat {
        travel <= limit ? travel : limit + (travel - limit) * 0.2
    }

    private func release() {
        guard let session, session.isValid else { return end() }
        let actions = session.shown
        guard session.offset != 0, !actions.isEmpty else { return animate(to: 0) }
        let sign: CGFloat = session.offset > 0 ? 1 : -1
        if session.armed {
            run(actions[0], sign: sign)
            return
        }
        // A flick counts for where the row would have coasted to, on the side it is on.
        let projected = (session.offset + session.velocity * 0.15) * sign
        let open = SwipeMetrics.openWidth(count: actions.count)
        animate(to: projected >= open / 2 ? sign * open : 0)
    }

    /// Runs `action` at once, so nothing that interrupts the animation can lose it.
    private func run(_ action: SwipeAction, sign: CGFloat) {
        guard let session else { return }
        session.committed = true
        action.perform()
        guard action.removesRow else { return animate(to: 0) }
        // Slides out while the list drops the row; a list that keeps it gets it back.
        animate(to: sign * session.cell.bounds.width) { [weak self, weak session] in
            guard let self, let session, session === self.session else { return }
            if isLive(session) { animate(to: 0) } else { reconcile() }
        }
    }

    /// Closes the open row, if any.
    func close() {
        guard let session, !session.committed else { return }
        animate(to: 0)
    }

    /// Forgets the swipe if its row left the list or its cell now shows another chat. Leaves the
    /// cell as it is: it is out of the list, and `ChatRowCell.configure` resets it on reuse.
    func reconcile() {
        guard let session, !isLive(session) else { return }
        self.session = nil
        stopLink()
    }

    /// Drops any swipe and gesture at once, for when the list goes away.
    func reset() {
        end()
        gesture = .idle
        swallowsMomentum = false
    }

    private func isLive(_ session: Session) -> Bool {
        session.isValid && (tableView?.row(for: session.cell) ?? -1) >= 0
    }

    private func end() {
        session?.cell.resetSwipe(animated: false)
        session = nil
        stopLink()
    }

    // MARK: Layout and animation

    private func apply(_ session: Session) {
        let edge: SwipeEdge? = session.offset > 0 ? .leading : session.offset < 0 ? .trailing : session.edge
        if edge != session.edge {
            session.edge = edge
            session.cell.setSwipeActions(session.shown) { [weak self, weak session] index in
                guard let self, let session, session === self.session else { return }
                self.run(session.shown[index], sign: session.offset > 0 ? 1 : -1)
            }
        }
        let count = session.shown.count
        let armed = count > 0 && abs(session.offset) >= SwipeMetrics.fullSwipeWidth(count: count, rowWidth: session.cell.bounds.width)
        // Only the fingers arm or disarm; the row settling after a release does not.
        if session.target == nil, armed != session.armed {
            session.armed = armed
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            startLink()
        }
        session.cell.setSwipe(offset: session.offset, armed: session.armProgress)
    }

    private func animate(to target: CGFloat, then onArrival: (() -> Void)? = nil) {
        guard let session else { return }
        session.target = target
        session.onArrival = onArrival
        startLink()
    }

    private func startLink() {
        guard link == nil, let tableView else { return }
        let link = tableView.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let session, session.isValid else { return end() }
        let dt = CGFloat(min(max(link.targetTimestamp - link.timestamp, 1.0 / 240), 1.0 / 30))
        let armTarget: CGFloat = session.armed ? 1 : 0
        session.armProgress += (armTarget - session.armProgress) * min(1, dt * 18)
        if abs(armTarget - session.armProgress) < 0.01 { session.armProgress = armTarget }

        var arrived = false
        if let target = session.target {
            // Critically damped spring, starting from the gesture's velocity.
            let stiffness: CGFloat = 320
            let accel = -stiffness * (session.offset - target) - 2 * stiffness.squareRoot() * session.velocity
            session.velocity += accel * dt
            var next = session.offset + session.velocity * dt
            // Closing never swings through to the other edge.
            if target == 0, next * session.offset < 0 { next = 0 }
            session.offset = next
            session.finger = next
            if abs(next - target) < 0.5, abs(session.velocity) < 8 {
                session.offset = target
                session.target = nil
                session.velocity = 0
                arrived = true
            }
        }
        apply(session)
        if arrived {
            let onArrival = session.onArrival
            session.onArrival = nil
            if session.offset == 0 { end() }
            onArrival?()
        }
        guard let current = self.session else { return stopLink() }
        if current.target == nil, current.armProgress == (current.armed ? 1 : 0) { stopLink() }
    }
}
