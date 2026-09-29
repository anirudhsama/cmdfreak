import Foundation
import GRDB

/// WhatsApp writes a mention into the text as "@" and the mentioned user's number: a LID for most
/// group members, a phone number for older messages. These resolve those numbers to display names.
public enum Mentions {
    /// The mentioned user numbers in `text`.
    static func users(in text: String) -> [Substring] {
        tokens(in: text).map(\.user)
    }

    /// Replaces every resolvable "@<number>" with "@<name>". `names` is keyed by user number.
    public static func apply(_ text: String, _ names: [String: String]) -> String {
        guard !names.isEmpty else { return text }
        var out = ""
        var cursor = text.startIndex
        for t in tokens(in: text) {
            guard let name = names[String(t.user)] else { continue }
            out += text[cursor..<t.range.lowerBound]
            out += "@" + name
            cursor = t.range.upperBound
        }
        return cursor == text.startIndex ? text : out + text[cursor...]
    }

    /// Names for the numbers mentioned in `texts`, keyed by user number. Unknown users are left out,
    /// so their mention stays as written.
    public static func names(_ db: Database, in texts: some Sequence<String?>) throws -> [String: String] {
        let users = Set(texts.lazy.compactMap { $0 }.filter { $0.contains("@") }.flatMap(users(in:)).map(String.init))
        guard !users.isEmpty else { return [:] }
        let own = try Set(String.fetchAll(db, sql: "SELECT value FROM meta WHERE key IN ('ownPn', 'ownLid')").map(JID.user))
        var out: [String: String] = [:]
        for user in users {
            if own.contains(user) { out[user] = "You"; continue }
            let lid = user + "@lid"
            let pn = try String.fetchOne(db, sql: "SELECT pn FROM jid_alias WHERE lid = ?", arguments: [lid])
            let candidates = [pn, lid, user + "@s.whatsapp.net"].compactMap { $0 }
            let contacts = Dictionary(try ContactRecord.fetchAll(db, keys: candidates).map { ($0.jid, $0) },
                                      uniquingKeysWith: { a, _ in a })
            let named = candidates.lazy.compactMap { contacts[$0]?.displayName.flatMap(ChatListQuery.unmasked) }.first
            // Nameless but known: show the phone number, like the phone does.
            let phone = pn ?? candidates.last.flatMap { contacts[$0] == nil ? nil : $0 }
            if let name = named ?? phone.flatMap(JID.phoneDisplay) { out[user] = name }
        }
        return out
    }

    private static func tokens(in text: String) -> [(range: Range<String.Index>, user: Substring)] {
        var out: [(Range<String.Index>, Substring)] = []
        var i = text.startIndex
        while let at = text[i...].firstIndex(of: "@") {
            let start = text.index(after: at)
            let end = text[start...].firstIndex(where: { !$0.isASCII || !$0.isNumber }) ?? text.endIndex
            let digits = text[start..<end]
            // Too short to be a user number, or part of a longer word ("a@1234567b").
            let followedByWord = end < text.endIndex && (text[end].isLetter || text[end] == "_")
            if digits.count >= 5, !followedByWord { out.append((at..<end, digits)) }
            i = end > start ? end : start
        }
        return out
    }
}
