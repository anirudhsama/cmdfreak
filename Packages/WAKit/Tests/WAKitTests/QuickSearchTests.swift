import Foundation
import Testing
@testable import WAKit

@Suite struct FuzzyMatcherTests {
    func s(_ q: String, _ name: String) -> Int? {
        FuzzyMatcher.score(FuzzyMatcher.normalize(q), in: FuzzyMatcher.normalize(name))
    }

    @Test func tiersAreOrdered() throws {
        let exact = try #require(s("family", "Family"))
        let prefix = try #require(s("fam", "Family"))
        let wordPrefix = try #require(s("sha", "Aarav Sharma"))
        let initials = try #require(s("as", "Aarav Sharma"))
        let substring = try #require(s("arm", "Aarav Sharma"))
        let subsequence = try #require(s("aavsh", "Aarav Sharma"))
        #expect(exact > prefix)
        #expect(prefix > wordPrefix)
        #expect(wordPrefix > initials)
        #expect(initials > substring)
        #expect(substring > subsequence)
    }

    @Test func foldsCaseAndDiacritics() {
        #expect(s("chloe", "Chloé Dubois") != nil)
        #expect(s("MULLER", "Felix Müller") != nil)
    }

    @Test func multiWordQueriesMatchWordsInAnyOrder() {
        #expect(s("sm ali", "Alice Smith") != nil)
        #expect(s("ali xyz", "Alice Smith") == nil)
    }

    @Test func rejectsNonMatchesAndScatter() {
        #expect(s("zq", "Alice Smith") == nil)
        #expect(s("x", "Alice") == nil)
        // Letters present but scattered with no structure across a long name.
        #expect(s("aeiou", "a long group name with every vowel somewhere in it ok") == nil)
    }

    @Test func shorterNameWinsWithinTier() throws {
        #expect(try #require(s("fam", "Family")) > #require(s("fam", "Family and friends")))
    }

    @Test func alternatesAreDiscounted() throws {
        let viaTitle = try #require(FuzzyMatcher.best("priya", title: "priya", alternates: []))
        let viaAlt = try #require(FuzzyMatcher.best("priya", title: "p. sharma", alternates: ["priya"]))
        #expect(viaTitle > viaAlt)
    }

    @Test func phoneDigits() {
        #expect(FuzzyMatcher.digits("+1 (555) 100-0003") == "15551000003")
        #expect(FuzzyMatcher.phoneScore("1555", phoneDigits: "15551000003") == FuzzyMatcher.wordPrefix)
        #expect(FuzzyMatcher.phoneScore("0003", phoneDigits: "15551000003") == FuzzyMatcher.substring)
        #expect(FuzzyMatcher.phoneScore("55", phoneDigits: "15551000003") == nil)
    }
}

@Suite struct QuickSearchRankingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func candidate(_ jid: String, _ title: String, activityDaysAgo: Double? = nil, hasChat: Bool = true, phone: String? = nil) -> QuickSearchCandidate {
        QuickSearchCandidate(jid: jid, kind: .dm, title: title, phone: phone, hasChat: hasChat,
                             lastActivityAt: activityDaysAgo.map { Int64(now.timeIntervalSince1970 - $0 * 86_400) })
    }

    @Test func textMatchDominates() {
        let cs = [candidate("a", "Sam Patel", activityDaysAgo: 0), candidate("b", "Samantha", activityDaysAgo: 60)]
        let ranked = QuickSearchRanker.rank(cs, query: "samantha", usage: QuickSearchUsage(), now: now)
        #expect(ranked.map(\.id) == ["b"])
    }

    @Test func recencyBreaksTies() {
        let cs = [candidate("old", "Alex Kim", activityDaysAgo: 40), candidate("new", "Alex Kim", activityDaysAgo: 0)]
        let ranked = QuickSearchRanker.rank(cs, query: "alex", usage: QuickSearchUsage(), now: now)
        #expect(ranked.first?.id == "new")
    }

    @Test func usageLiftsFrequentPick() {
        let cs = [candidate("a", "Maria Silva", activityDaysAgo: 1), candidate("b", "Mario Rossi", activityDaysAgo: 1)]
        var usage = QuickSearchUsage()
        #expect(QuickSearchRanker.rank(cs, query: "mari", usage: usage, now: now).first?.id == "a")
        for _ in 0..<3 { usage.recordSelection(of: "b", query: "mari", now: now) }
        #expect(QuickSearchRanker.rank(cs, query: "mari", usage: usage, now: now).first?.id == "b")
        #expect(usage.affinity(of: "b", query: "mario") == 3)
        #expect(usage.affinity(of: "b", query: "zed") == 0)
    }

    @Test func usageDecays() {
        var usage = QuickSearchUsage()
        usage.recordSelection(of: "x", query: "", now: now.addingTimeInterval(-7 * 86_400))
        #expect(abs(usage.frecency(of: "x", now: now) - 0.5) < 0.001)
        usage.recordVisit(of: "y", now: now)
        #expect(abs(usage.frecency(of: "y", now: now) - 0.3) < 0.001)
    }

    @Test func emptyQueryOrdersByUsageThenRecency() {
        let cs = [candidate("a", "A", activityDaysAgo: 0), candidate("b", "B", activityDaysAgo: 3), candidate("c", "C", activityDaysAgo: 30)]
        var usage = QuickSearchUsage()
        usage.recordSelection(of: "c", query: "", now: now)
        usage.recordSelection(of: "c", query: "", now: now)
        #expect(QuickSearchRanker.rank(cs, query: "", usage: usage, now: now).map(\.id) == ["c", "a", "b"])
    }

    @Test func phoneQueryMatches() {
        let cs = [candidate("a", "Nadia", phone: "15551000042"), candidate("b", "Omar", phone: "4478000000")]
        #expect(QuickSearchRanker.rank(cs, query: "+1 555 100", usage: QuickSearchUsage(), now: now).map(\.id) == ["a"])
    }

    @Test func usageRoundTripsThroughJSON() throws {
        var usage = QuickSearchUsage()
        usage.recordSelection(of: "a", query: "al", now: now)
        let decoded = try JSONDecoder().decode(QuickSearchUsage.self, from: JSONEncoder().encode(usage))
        #expect(decoded == usage)
    }
}

@Suite struct QuickSearchQueryTests {
    @Test func prefiltersChatsAndContacts() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([
            .contacts(contacts: [
                BridgeContact(jid: F.alicePN, fullName: "Alice Smith", firstName: nil, pushName: "Ali", phone: "15551110000"),
                BridgeContact(jid: F.bob, fullName: "Bob Müller", firstName: nil, pushName: nil, phone: "15552220000"),
                BridgeContact(jid: "15553330000@s.whatsapp.net", fullName: nil, firstName: nil, pushName: "Carla", phone: nil),
            ]),
            .messages(messages: [F.message("m1", chat: F.alicePN), F.message("m2", chat: F.group, sender: F.bob)], updates: []),
        ])

        let byName = try await db.quickSearchCandidates(query: "alsm", scope: .all)
        #expect(byName.map(\.jid) == [F.alicePN])
        #expect(byName.first?.alternateNames == ["Ali"])

        // Bob has no chat; saved contacts show up in `.all` with hasChat == false, diacritics folded.
        let bob = try await db.quickSearchCandidates(query: "muller", scope: .all)
        #expect(bob.map(\.jid) == [F.bob])
        #expect(bob.first?.hasChat == false)

        // Unsaved (push-name only) contacts only in `.contacts`; groups never there.
        #expect(try await db.quickSearchCandidates(query: "carla", scope: .all).isEmpty)
        #expect(try await db.quickSearchCandidates(query: "carla", scope: .contacts).map(\.jid) == ["15553330000@s.whatsapp.net"])
        let contactsAll = try await db.quickSearchCandidates(query: "", scope: .contacts)
        #expect(!contactsAll.contains { $0.kind == .group })

        #expect(try await db.quickSearchCandidates(query: "2220", scope: .all).map(\.jid) == [F.bob])
        // Empty query in `.all`: chats only.
        #expect(Set(try await db.quickSearchCandidates(query: "", scope: .all).map(\.jid)) == [F.alicePN, F.group])
    }

    @Test func createLocalChatMakesItListable() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.createLocalChat(F.bob, now: 1_700_000_000)
        let items = try await db.pool.read { try ChatListQuery.fetch($0, filter: .chats) }
        #expect(items.map(\.id) == [F.bob])
        // Idempotent and does not clobber existing activity.
        try await ingest.createLocalChat(F.bob, now: 1_800_000_000)
        let chat = try await db.pool.read { try ChatRecord.fetchOne($0, key: F.bob) }
        #expect(chat?.lastActivityAt == 1_700_000_000)
    }

    @Test func likePatternEscapes() {
        #expect(QuickSearchQuery.subsequencePattern("a b") == "%a%b%")
        #expect(QuickSearchQuery.subsequencePattern("5%_") == "%5%\\%%\\_%")
        #expect(QuickSearchQuery.subsequencePattern("") == "")
    }
}
