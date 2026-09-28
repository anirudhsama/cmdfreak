import AppKit

/// "Today", "Yesterday", or a full date, centred in a pill.
final class DaySeparatorCell: NSTableCellView {
    private static let dayFormat = Date.FormatStyle(date: .complete, time: .omitted)
    private var text = ""

    override var isFlipped: Bool { true }

    static func title(forDayStart ts: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let cal = Calendar.autoupdatingCurrent
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(dayFormat)
    }

    func configure(dayStart: Int64) {
        text = Self.title(forDayStart: dayStart)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let attr = NSAttributedString(string: text, attributes: [
            .font: MessageTextConfiguration.daySeparator, .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let size = attr.size()
        let pill = NSRect(x: (bounds.width - size.width - 20) / 2, y: (bounds.height - size.height - 6) / 2,
                          width: size.width + 20, height: size.height + 6).integral
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill(with: MessageTextConfiguration.systemPill)
        attr.draw(at: NSPoint(x: pill.minX + 10, y: pill.minY + 3))
    }
}

final class UnreadSeparatorCell: NSTableCellView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let attr = NSAttributedString(string: "Unread messages", attributes: [
            .font: MessageTextConfiguration.daySeparator, .foregroundColor: Palette.green,
        ])
        let size = attr.size()
        let y = bounds.midY
        Palette.green.withAlphaComponent(0.35).setFill()
        let inset = MessageTextConfiguration.Metrics.horizontalInset
        NSRect(x: inset, y: y, width: (bounds.width - size.width) / 2 - inset - 10, height: 1).fill()
        NSRect(x: (bounds.width + size.width) / 2 + 10, y: y, width: (bounds.width - size.width) / 2 - inset - 10, height: 1).fill()
        attr.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: y - size.height / 2))
    }
}

/// Forwards keys the list does not consume (typing, Esc, Space) to a handler.
final class ChatTableView: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    /// Row backgrounds are drawn by the cells; keep the table transparent.
    override func drawBackground(inClipRect clipRect: NSRect) {}
}
