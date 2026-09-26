import Foundation
import GRDB

// MARK: - Candidates

/// What the command bar searches over.
public enum QuickSearchScope: Sendable, Hashable {
    /// Chats (any kind, archived included) plus saved contacts that have no chat yet.
    case all
    /// People only: DM chats plus every contact with a phone-number JID (⌘N, new chat).
    case contacts
}

/// A person or chat the command bar can open. `hasChat == false` means opening it starts a new DM.
public struct QuickSearchCandidate: Sendable, Hashable, Identifiable {
    public var jid: String
    public var kind: ChatKind
    public var title: String
    /// Other names the candidate is known by (saved name, push name), already distinct from `title`.
    public var alternateNames: [String]
    /// Digits only, no "+".
    public var phone: String?
    public var hasChat: Bool
    public var archived: Bool
    public var lastActivityAt: Int64?
    public var avatarPath: String?

    public var id: String { jid }

    public init(jid: String, kind: ChatKind, title: String, alternateNames: [String] = [], phone: String? = nil,
                hasChat: Bool = true, archived: Bool = false, lastActivityAt: Int64? = nil, avatarPath: String? = nil) {
        self.jid = jid
        self.kind = kind
        self.title = title
        self.alternateNames = alternateNames
        self.phone = phone
        self.hasChat = hasChat
        self.archived = archived
        self.lastActivityAt = lastActivityAt
        self.avatarPath = avatarPath
    }
}

/// SQL prefilter for the command bar. A subsequence `LIKE` over diacritic-folded names (and a
/// digit substring over phone numbers) narrows the table; `QuickSearchRanker` scores the rest.
public enum QuickSearchQuery {
    static let fold = DatabaseFunction("wa_fold", argumentCount: 1, pure: true) { values in
        String.fromDatabaseValue(values[0]).map(FuzzyMatcher.normalize)
    }

    /// Recent chats (empty query) or prefiltered matches, newest activity first.
    public static func candidates(_ db: Database, query: String, scope: QuickSearchScope, limit: Int = 500) throws -> [QuickSearchCandidate] {
        db.add(function: fold)
        let normalized = FuzzyMatcher.normalize(query)
        let digits = FuzzyMatcher.digits(query)
        let pattern = subsequencePattern(normalized)
        let digitPattern = digits.count >= 3 ? "%\(digits)%" : ""
        let filtering = !normalized.isEmpty

        let phoneExpr = "COALESCE(ct.phone, CASE WHEN c.jid LIKE '%@s.whatsapp.net' THEN substr(c.jid, 1, instr(c.jid, '@') - 1) END)"
        let namesExpr = "wa_fold(IFNULL(c.name,'') || ' ' || IFNULL(ct.fullName,'') || ' ' || IFNULL(ct.firstName,'') || ' ' || IFNULL(ct.pushName,''))"
        var chatWhere = ["(c.lastActivityAt IS NOT NULL OR c.pinnedAt IS NOT NULL)"]
        if scope == .contacts { chatWhere.append("c.kind = 'dm'") }
        if filtering {
            chatWhere.append("(\(namesExpr) LIKE :pattern ESCAPE '\\' OR (:digits != '' AND \(phoneExpr) LIKE :digits))")
        }
        let chatSQL = """
            SELECT c.jid, c.kind, c.name, c.lastActivityAt, c.archived, c.avatarPath,
                   ct.fullName, ct.firstName, ct.pushName, \(phoneExpr) AS phone
            FROM chat c LEFT JOIN contact ct ON ct.jid = c.jid
            WHERE \(chatWhere.joined(separator: " AND "))
            ORDER BY c.lastActivityAt IS NULL, c.lastActivityAt DESC
            LIMIT :limit
            """
        let args: StatementArguments = ["pattern": pattern, "digits": digitPattern, "limit": limit]
        var out: [QuickSearchCandidate] = try Row.fetchAll(db, sql: chatSQL, arguments: args).map { row in
            let jid: String = row["jid"]
            let contact = ContactRecord(jid: row["jid"], fullName: row["fullName"], firstName: row["firstName"],
                                        pushName: row["pushName"], phone: row["phone"])
            var chat = ChatRecord(jid: jid, kind: row["kind"] as ChatKind?)
            chat.name = row["name"]
            let title = ChatListQuery.title(chat, chat.kind == .dm ? contact : nil)
            return QuickSearchCandidate(
                jid: chat.jid, kind: chat.kind, title: title,
                alternateNames: chat.kind == .dm ? alternates(contact, excluding: title) : [],
                phone: chat.kind == .dm ? contact.phone : nil, hasChat: true, archived: row["archived"],
                lastActivityAt: row["lastActivityAt"], avatarPath: row["avatarPath"])
        }

        // Contacts without a chat: saved contacts for `.all`, anyone reachable for `.contacts`.
        // With an empty query only `.contacts` lists them (after the chats).
        guard filtering || scope == .contacts else { return out }
        var contactWhere = [
            "ct.jid LIKE '%@s.whatsapp.net'",
            "NOT EXISTS (SELECT 1 FROM chat c WHERE c.jid = ct.jid AND (c.lastActivityAt IS NOT NULL OR c.pinnedAt IS NOT NULL))",
        ]
        contactWhere.append(scope == .all ? "IFNULL(ct.fullName, '') != ''"
                                          : "(IFNULL(ct.fullName,'') != '' OR IFNULL(ct.pushName,'') != '')")
        if filtering {
            contactWhere.append("""
                (wa_fold(IFNULL(ct.fullName,'') || ' ' || IFNULL(ct.firstName,'') || ' ' || IFNULL(ct.pushName,'')) LIKE :pattern ESCAPE '\\'
                 OR (:digits != '' AND IFNULL(ct.phone, substr(ct.jid, 1, instr(ct.jid, '@') - 1)) LIKE :digits))
                """)
        }
        let contactSQL = """
            SELECT * FROM contact ct WHERE \(contactWhere.joined(separator: " AND "))
            ORDER BY COALESCE(ct.fullName, ct.pushName) COLLATE NOCASE LIMIT :limit
            """
        for contact in try ContactRecord.fetchAll(db, sql: contactSQL, arguments: args) {
            let title = contact.displayName ?? JID.phoneDisplay(contact.jid) ?? contact.jid
            out.append(QuickSearchCandidate(
                jid: contact.jid, kind: .dm, title: title, alternateNames: alternates(contact, excluding: title),
                phone: contact.phone ?? JID.user(contact.jid), hasChat: false))
        }
        return out
    }

    private static func alternates(_ c: ContactRecord, excluding title: String) -> [String] {
        var seen: Set<String> = [title]
        return [c.fullName, c.firstName, c.pushName].compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// "ab c" → "%a%b%c%" with LIKE metacharacters escaped. Empty for an empty query.
    static func subsequencePattern(_ normalized: String) -> String {
        let chars = normalized.filter { !$0.isWhitespace }
        guard !chars.isEmpty else { return "" }
        var p = "%"
        for ch in chars {
            if ch == "%" || ch == "_" || ch == "\\" { p.append("\\") }
            p.append(ch)
            p.append("%")
        }
        return p
    }
}

extension AppDatabase {
    public func quickSearchCandidates(query: String, scope: QuickSearchScope, limit: Int = 500) async throws -> [QuickSearchCandidate] {
        try await pool.read { db in try QuickSearchQuery.candidates(db, query: query, scope: scope, limit: limit) }
    }
}

// MARK: - Usage

/// Command-bar usage: when each chat was picked (and opened at all), and which chats were picked
/// for which typed prefix. Persisted as a small JSON file by the UI layer.
public struct QuickSearchUsage: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        /// Unix seconds, oldest first, capped.
        var selections: [Double] = []
        var visits: [Double] = []
        var latest: Double { max(selections.last ?? 0, visits.last ?? 0) }
    }

    var chats: [String: Entry] = [:]
    /// Normalized query prefix → jid → times picked.
    var prefixes: [String: [String: Int]] = [:]

    static let maxStamps = 12
    static let maxChats = 500
    static let prefixLength = 4
    static let halfLife: Double = 7 * 86_400

    public init() {}

    /// The user picked `jid` from the command bar after typing `query`.
    public mutating func recordSelection(of jid: String, query: String, now: Date = Date()) {
        append(&chats[jid, default: Entry()].selections, now.timeIntervalSince1970)
        let key = Self.prefixKey(query)
        if !key.isEmpty { prefixes[key, default: [:]][jid, default: 0] += 1 }
        prune()
    }

    /// `jid` was opened by any means (list click, shortcut).
    public mutating func recordVisit(of jid: String, now: Date = Date()) {
        append(&chats[jid, default: Entry()].visits, now.timeIntervalSince1970)
        prune()
    }

    /// Exponentially decayed use count: a pick is worth 1, a plain visit 0.3.
    public func frecency(of jid: String, now: Date = Date()) -> Double {
        guard let e = chats[jid] else { return 0 }
        let t = now.timeIntervalSince1970
        func decay(_ s: Double) -> Double { pow(0.5, max(0, t - s) / Self.halfLife) }
        return e.selections.reduce(0) { $0 + decay($1) } + 0.3 * e.visits.reduce(0) { $0 + decay($1) }
    }

    /// Times `jid` was picked after typing a query starting like `query`.
    public func affinity(of jid: String, query: String) -> Int {
        let key = Self.prefixKey(query)
        guard !key.isEmpty else { return 0 }
        return prefixes[key]?[jid] ?? 0
    }

    static func prefixKey(_ query: String) -> String {
        String(FuzzyMatcher.normalize(query).prefix(prefixLength))
    }

    private func append(_ stamps: inout [Double], _ t: Double) {
        stamps.append(t)
        if stamps.count > Self.maxStamps { stamps.removeFirst(stamps.count - Self.maxStamps) }
    }

    private mutating func prune() {
        guard chats.count > Self.maxChats else { return }
        let keep = Set(chats.sorted { $0.value.latest > $1.value.latest }.prefix(Self.maxChats).map(\.key))
        chats = chats.filter { keep.contains($0.key) }
        for (k, v) in prefixes {
            let kept = v.filter { keep.contains($0.key) }
            prefixes[k] = kept.isEmpty ? nil : kept
        }
    }
}

// MARK: - Ranking

public struct RankedCandidate: Sendable, Hashable, Identifiable {
    public var candidate: QuickSearchCandidate
    public var score: Double
    public var id: String { candidate.id }

    public init(candidate: QuickSearchCandidate, score: Double) {
        self.candidate = candidate
        self.score = score
    }
}

public enum QuickSearchRanker {
    /// Scores `candidates` for `query`, drops non-matches, and returns the best `limit`.
    /// Text match dominates; usage (frecency plus prefix affinity) and recent activity break ties
    /// within a tier and can lift a well-used chat over a slightly better text match.
    public static func rank(_ candidates: [QuickSearchCandidate], query: String, usage: QuickSearchUsage,
                            now: Date = Date(), limit: Int = 50) -> [RankedCandidate] {
        let q = FuzzyMatcher.normalize(query)
        let qDigits = FuzzyMatcher.digits(query)
        let digitQuery = qDigits.count >= 3 && qDigits.count * 2 >= q.filter { !$0.isWhitespace }.count
        var out: [RankedCandidate] = []
        out.reserveCapacity(candidates.count)
        for c in candidates {
            var match = 0
            if !q.isEmpty {
                let nameScore = FuzzyMatcher.best(q, title: FuzzyMatcher.normalize(c.title),
                                                  alternates: c.alternateNames.map(FuzzyMatcher.normalize))
                let phoneScore = digitQuery ? c.phone.flatMap { FuzzyMatcher.phoneScore(qDigits, phoneDigits: FuzzyMatcher.digits($0)) } : nil
                guard let best = [nameScore, phoneScore].compactMap({ $0 }).max() else { continue }
                match = best
            }
            out.append(RankedCandidate(candidate: c, score: Double(match) + boost(c, query: q, usage: usage, now: now)))
        }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.candidate.title < $1.candidate.title }
        return Array(out.prefix(limit))
    }

    static func boost(_ c: QuickSearchCandidate, query: String, usage: QuickSearchUsage, now: Date) -> Double {
        var b = min(usage.frecency(of: c.jid, now: now) * 40, 160)
        b += Double(min(usage.affinity(of: c.jid, query: query) * 60, 180))
        if let ts = c.lastActivityAt {
            let age = max(0, now.timeIntervalSince1970 - Double(ts))
            b += 80 * exp(-age / (14 * 86_400))
        }
        if !c.hasChat { b -= 20 }
        if c.archived { b -= 15 }
        return b
    }
}
