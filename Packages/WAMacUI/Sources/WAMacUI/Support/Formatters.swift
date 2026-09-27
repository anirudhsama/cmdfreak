import Foundation

/// Cached formatters for the chat list. Formatting runs when a row's model changes, not on scroll.
@MainActor
enum ChatTimeFormatter {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()
    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()
    private static let calendar = Calendar.autoupdatingCurrent

    static func string(fromUnixSeconds ts: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        if calendar.isDateInToday(date) { return time.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo {
            return weekday.string(from: date)
        }
        return shortDate.string(from: date)
    }
}

enum Initials {
    /// Up to two letters from the first two words of `name`; empty for names without letters
    /// (bare phone numbers), which avatars render as a person glyph.
    static func from(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        let letters = words.compactMap { $0.first(where: \.isLetter) }
        return String(letters).uppercased()
    }
}
