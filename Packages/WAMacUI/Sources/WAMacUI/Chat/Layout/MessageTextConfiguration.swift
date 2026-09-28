import AppKit

/// The single source of fonts, colors and metrics for bubbles. Measurement (`LayoutPlanner`) and
/// rendering (`MessageCell`) both read from here so heights match exactly.
enum MessageTextConfiguration {
    // MARK: Fonts

    nonisolated(unsafe) static let body = NSFont.systemFont(ofSize: 14)
    nonisolated(unsafe) static let bodyItalic: NSFont = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
    nonisolated(unsafe) static let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    nonisolated(unsafe) static let bigEmoji = NSFont.systemFont(ofSize: 36)
    nonisolated(unsafe) static let sender = NSFont.systemFont(ofSize: 12, weight: .semibold)
    nonisolated(unsafe) static let meta = NSFont.systemFont(ofSize: 10.5)
    nonisolated(unsafe) static let quoteName = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    nonisolated(unsafe) static let quoteBody = NSFont.systemFont(ofSize: 12)
    nonisolated(unsafe) static let card = NSFont.systemFont(ofSize: 12.5)
    nonisolated(unsafe) static let cardTitle = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    nonisolated(unsafe) static let cardSecondary = NSFont.systemFont(ofSize: 11)
    nonisolated(unsafe) static let system = NSFont.systemFont(ofSize: 11.5)
    nonisolated(unsafe) static let daySeparator = NSFont.systemFont(ofSize: 11, weight: .medium)
    nonisolated(unsafe) static let reaction = NSFont.systemFont(ofSize: 12)

    nonisolated(unsafe) static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineBreakStrategy = []
        return p
    }()

    nonisolated(unsafe) static let bodyAttributes: [NSAttributedString.Key: Any] = [
        .font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
    ]
    nonisolated(unsafe) static let metaAttributes: [NSAttributedString.Key: Any] = [
        .font: meta, .foregroundColor: NSColor.secondaryLabelColor,
    ]

    // MARK: Colors

    /// iMessage-shaped bubbles in WhatsApp's colors. Both are opaque so the tail can be filled as a
    /// separate shape without a visible seam.
    static let outgoingBubble = Palette.outgoingBubble
    static let incomingBubble = Palette.incomingBubble
    static let quoteBackground = NSColor(name: "quoteBackground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 0.22)
            : NSColor(white: 0, alpha: 0.05)
    }
    static let systemPill = NSColor(name: "systemPill") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.08)
            : NSColor(white: 0, alpha: 0.05)
    }
    static let readTick = Palette.readTick

    /// A stable per-sender hue for group sender names.
    static func senderColor(for jid: String) -> NSColor {
        var h: UInt32 = 2_166_136_261
        for b in jid.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        let hue = CGFloat(h % 360) / 360
        return NSColor(name: "sender-\(h % 360)") { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hue: hue, saturation: dark ? 0.55 : 0.7, brightness: dark ? 0.9 : 0.55, alpha: 1)
        }
    }

    // MARK: Metrics

    enum Metrics {
        static let horizontalInset: CGFloat = 16
        static let bubbleMaxWidthFraction: CGFloat = 0.72
        static let bubbleMaxWidth: CGFloat = 520
        static let bubbleMinWidth: CGFloat = 60
        static let bubblePaddingH: CGFloat = 12
        static let bubblePaddingV: CGFloat = 7
        static let bubbleRadius: CGFloat = 17
        static let groupGap: CGFloat = 2
        static let messageGap: CGFloat = 10
        static let senderHeight: CGFloat = 16
        static let metaGap: CGFloat = 6
        static let metaHeight: CGFloat = 13
        static let tickWidth: CGFloat = 16
        static let quoteHeight: CGFloat = 44
        static let quoteBar: CGFloat = 3
        static let quoteRadius: CGFloat = 6
        static let mediaInset: CGFloat = 3
        static let mediaMinWidth: CGFloat = 140
        static let mediaMaxHeight: CGFloat = 340
        static let mediaRadius: CGFloat = 10
        static let stickerSize: CGFloat = 160
        static let cardWidth: CGFloat = 290
        static let documentHeight: CGFloat = 56
        static let audioHeight: CGFloat = 48
        static let reactionHeight: CGFloat = 22
        static let reactionOverlap: CGFloat = 8
        static let reactionGap: CGFloat = 4
        static let daySeparatorHeight: CGFloat = 36
        static let unreadSeparatorHeight: CGFloat = 28
        static let systemPaddingV: CGFloat = 6
        static let systemPaddingH: CGFloat = 10
        static let listTopInset: CGFloat = 8
    }
}
