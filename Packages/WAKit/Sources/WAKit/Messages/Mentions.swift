import Foundation
import GRDB

/// A mentioned user as shown in a message.
public struct Mention: Hashable, Sendable {
    public var name: String
    /// The user's chat JID (phone-number form when known); nil for yourself.
    public var jid: String?
    /// "+<digits>" when the phone number is known.
    public var phone: String?

    public init(name: String, jid: String?, phone: String?) {
        self.name = name
        self.jid = jid
        self.phone = phone
    }
}

/// WhatsApp writes a mention into the text as "@" and the mentioned user's number: a LID for most
/// group members, a phone number for older messages. These resolve those numbers to display names.
public enum Mentions {
    /// The mentioned user numbers in `text`.
    static func users(in text: String) -> [Substring] {
        tokens(in: text).map(\.user)
    }

    /// Every "@<number>" in `text` as a UTF-16 range, with its user number.
    public static func ranges(in text: String) -> [(range: NSRange, user: String)] {
        tokens(in: text).map { (NSRange($0.range, in: text), String($0.user)) }
    }

    /// Replaces every resolvable "@<number>" with "@<name>". `names` is keyed by user number.
    public static func apply(_ text: String, _ names: [String: String]) -> String {
        apply(text) { names[$0] }
    }

    public static func apply(_ text: String, _ mentions: [String: Mention]) -> String {
        apply(text) { mentions[$0]?.name }
    }

    private static func apply(_ text: String, name: (String) -> String?) -> String {
        guard text.contains("@") else { return text }
        var out = ""
        var cursor = text.startIndex
        for t in tokens(in: text) {
            guard let name = name(String(t.user)) else { continue }
            out += text[cursor..<t.range.lowerBound]
            out += "@" + name
            cursor = t.range.upperBound
        }
        return cursor == text.startIndex ? text : out + text[cursor...]
    }

    /// Names for the numbers mentioned in `texts`, keyed by user number, guessing which user each
    /// number is (see `Resolver`). Unknown users are left out, so their mention stays as written.
    public static func names(_ db: Database, in texts: some Sequence<String?>) throws -> [String: String] {
        var resolver = try Resolver(db)
        var out: [String: String] = [:]
        for text in texts {
            for (user, mention) in try resolver.mentions(in: text, jids: nil) { out[user] = mention.name }
        }
        return out
    }

    /// Stored form of a message's mentioned JIDs: nil when there are none and the text has no "@", so
    /// messages without mentions store nothing. nil otherwise means "not recorded" (see `Resolver`).
    static func stored(_ jids: [String], text: String?) -> [String]? {
        jids.isEmpty && !(text?.contains("@") ?? false) ? nil : jids
    }

    /// Resolves the users a text mentions, caching lookups across a page of messages.
    struct Resolver {
        private let db: Database
        private let own: Set<String>
        private var cache: [String: Mention?] = [:]

        init(_ db: Database) throws {
            self.db = db
            own = try Set(String.fetchAll(db, sql: "SELECT value FROM meta WHERE key IN ('ownPn', 'ownLid')").map(JID.user))
        }

        /// The users mentioned in `text`, keyed by user number. `jids` are the JIDs the message says it
        /// mentions: only "@<number>"s among them count. nil for messages stored before those were
        /// kept (and quotes filled from their target), where each number is tried as a LID, then a
        /// phone number. Unknown users are left out.
        mutating func mentions(in text: String?, jids: [String]?) throws -> [String: Mention] {
            guard let text, text.contains("@") else { return [:] }
            let users = Set(Mentions.users(in: text).map(String.init))
            let targets: [(user: String, jid: String?)] = jids.map { jids in
                jids.map(Self.bare).map { (JID.user($0), $0) }.filter { users.contains($0.user) }
            } ?? users.map { ($0, nil) }
            var out: [String: Mention] = [:]
            for t in targets {
                let key = t.user + " " + (t.jid ?? "")
                if cache[key] == nil { cache[key] = .some(try resolve(t.user, jid: t.jid)) }
                if let mention = cache[key] ?? nil { out[t.user] = mention }
            }
            return out
        }

        /// How a mention of `jid` reads, as `mentions(in:jids:)` would resolve it.
        mutating func mention(of jid: String) throws -> Mention? {
            let jid = Self.bare(jid)
            let key = JID.user(jid) + " " + jid
            if cache[key] == nil { cache[key] = .some(try resolve(JID.user(jid), jid: jid)) }
            return cache[key] ?? nil
        }

        /// "<user>@<server>" without a device or agent suffix, as contacts and aliases are keyed.
        static func bare(_ jid: String) -> String {
            guard let at = jid.firstIndex(of: "@") else { return jid }
            let user = jid[..<at].prefix { $0 != ":" && $0 != "." }
            return String(user + jid[at...])
        }

        private func resolve(_ user: String, jid: String?) throws -> Mention? {
            if own.contains(user) { return Mention(name: "You", jid: nil, phone: nil) }
            // Phone-number and LID forms of the user; contacts may be stored under either.
            var pn: String?
            let candidates: [String]
            switch jid {
            case let jid? where JID.isLid(jid):
                pn = try pnFor(jid)
                candidates = [pn, jid].compactMap { $0 }
            case let jid? where JID.isPhoneNumber(jid):
                pn = jid
                candidates = [jid, try String.fetchOne(db, sql: "SELECT lid FROM jid_alias WHERE pn = ?", arguments: [jid])].compactMap { $0 }
            case let jid?:
                candidates = [jid]
            case nil:
                let lid = user + "@lid"
                pn = try pnFor(lid)
                candidates = [pn, lid, user + "@s.whatsapp.net"].compactMap { $0 }
            }
            let contacts = Dictionary(try ContactRecord.fetchAll(db, keys: candidates).map { ($0.jid, $0) },
                                      uniquingKeysWith: { a, _ in a })
            let named = candidates.lazy.compactMap { jid in
                contacts[jid]?.displayName.flatMap(ChatListQuery.unmasked).map { (jid, $0) }
            }.first
            // An unnamed guessed number counts as a phone number only if we know that contact.
            if jid == nil, pn == nil, named == nil, let phone = candidates.last, contacts[phone] != nil { pn = phone }
            // Nameless but known: show the phone number, like the phone does.
            guard let chat = pn ?? named?.0 else { return nil }
            let phone = JID.phoneDisplay(chat)
            guard let name = named?.1 ?? phone else { return nil }
            return Mention(name: name, jid: chat, phone: phone)
        }

        private func pnFor(_ lid: String) throws -> String? {
            try String.fetchOne(db, sql: "SELECT pn FROM jid_alias WHERE lid = ?", arguments: [lid])
        }
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
