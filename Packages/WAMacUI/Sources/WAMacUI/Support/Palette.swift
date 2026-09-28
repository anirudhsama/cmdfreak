import AppKit
import SwiftUI

/// WhatsApp's colors. Explicit rather than an app accent color: macOS ignores an app's accent
/// whenever the user has picked their own in System Settings.
enum Palette {
    /// Interactive green: selection in the rail, buttons, the reply bar, the unread divider.
    /// Dark enough for white text.
    static let green = NSColor(name: "waGreen") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.129, green: 0.753, blue: 0.388, alpha: 1)  // #21C063
            : NSColor(srgbRed: 0.114, green: 0.667, blue: 0.380, alpha: 1)  // #1DAA61
    }

    /// The chat list's selected row while the list has keyboard focus, under white text. Darker than
    /// `green` in dark mode, where the brighter green would not hold white text.
    static let selection = NSColor(name: "waSelection") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.078, green: 0.525, blue: 0.294, alpha: 1)  // #14864B
            : NSColor(srgbRed: 0.114, green: 0.667, blue: 0.380, alpha: 1)  // #1DAA61
    }

    /// Unread badges and dots: WhatsApp's brand green.
    static let badge = NSColor(name: "waBadge") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.129, green: 0.753, blue: 0.388, alpha: 1)  // #21C063
            : NSColor(srgbRed: 0.145, green: 0.827, blue: 0.400, alpha: 1)  // #25D366
    }

    /// Count text on `badge`: white in light mode, near-black in dark (as WhatsApp does).
    static let onBadge = NSColor(name: "waOnBadge") { appearance in
        appearance.isDark ? NSColor(srgbRed: 0.067, green: 0.106, blue: 0.129, alpha: 1) : .white
    }

    /// Own messages: WhatsApp's pale green, deep green in dark mode.
    static let outgoingBubble = NSColor(name: "waOutgoingBubble") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.078, green: 0.302, blue: 0.216, alpha: 1)  // #144D37
            : NSColor(srgbRed: 0.851, green: 0.992, blue: 0.827, alpha: 1)  // #D9FDD3
    }

    static let incomingBubble = NSColor(name: "waIncomingBubble") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.23, green: 0.23, blue: 0.24, alpha: 1)
            : NSColor(srgbRed: 0.91, green: 0.91, blue: 0.92, alpha: 1)
    }

    /// Read receipts: WhatsApp's tick blue.
    static let readTick = NSColor(srgbRed: 0.325, green: 0.741, blue: 0.922, alpha: 1)  // #53BDEB
}

extension Color {
    static let waGreen = Color(nsColor: Palette.green)
    static let waSelection = Color(nsColor: Palette.selection)
    static let waBadge = Color(nsColor: Palette.badge)
    static let waOnBadge = Color(nsColor: Palette.onBadge)
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
