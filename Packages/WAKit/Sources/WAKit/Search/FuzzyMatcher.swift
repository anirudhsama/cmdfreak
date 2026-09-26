import Foundation

/// Scores how well a typed query matches a name. Pure and allocation-light so it can run over a
/// few thousand candidates per keystroke. Higher is better; `nil` means no match.
///
/// Tiers (best first): exact, prefix, word-prefix, initials, substring, subsequence. Multi-word
/// queries also match when every word matches some word of the name ("ali sm" → "Alice Smith").
public enum FuzzyMatcher {
    public static let exact = 1000
    public static let prefix = 900
    public static let wordPrefix = 800
    public static let initials = 700
    public static let allWords = 650
    public static let substring = 550
    public static let subsequenceMax = 450

    /// Lowercased, diacritic- and width-folded, with runs of whitespace collapsed.
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Digits only, for phone-number matching.
    public static func digits(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.properties.numericType == .decimal && $0.isASCII }.map(Character.init))
    }

    /// `query` and `name` must already be `normalize`d.
    public static func score(_ query: String, in name: String) -> Int? {
        guard !query.isEmpty, !name.isEmpty else { return nil }
        if query == name { return exact }
        // Shorter names rank above longer ones within a tier.
        let lengthPenalty = min(name.count - query.count, 40)
        if name.hasPrefix(query) { return prefix - lengthPenalty }

        let q = Array(query.unicodeScalars)
        let n = Array(name.unicodeScalars)
        let starts = wordStarts(n)

        if let pos = firstRange(of: q, in: n) {
            if starts.contains(pos) { return wordPrefix - lengthPenalty }
            if !query.contains(" ") && isInitials(q, starts: starts, n: n) { return initials - lengthPenalty }
            return substring - min(pos, 40) - lengthPenalty / 2
        }
        if !query.contains(" ") && isInitials(q, starts: starts, n: n) { return initials - lengthPenalty }
        if query.contains(" "), let s = allWordsScore(query, name) { return s }
        return subsequence(q, n, starts: starts)
    }

    /// Best score of `query` over several names (title first; alternates slightly discounted).
    public static func best(_ query: String, title: String, alternates: [String]) -> Int? {
        var best = score(query, in: title)
        for alt in alternates {
            guard let s = score(query, in: alt).map({ $0 - 30 }) else { continue }
            best = max(best ?? s, s)
        }
        return best
    }

    /// Phone matching on digits: prefix (ignoring a leading country code the user may omit) or substring.
    public static func phoneScore(_ queryDigits: String, phoneDigits: String) -> Int? {
        guard queryDigits.count >= 3, !phoneDigits.isEmpty else { return nil }
        if phoneDigits == queryDigits { return exact }
        if phoneDigits.hasPrefix(queryDigits) { return wordPrefix }
        if phoneDigits.contains(queryDigits) { return substring }
        return nil
    }

    // MARK: Internals

    private static func wordStarts(_ n: [Unicode.Scalar]) -> Set<Int> {
        var starts: Set<Int> = [0]
        guard n.count > 1 else { return starts }
        for i in 1..<n.count {
            let prev = n[i - 1]
            if !prev.properties.isAlphabetic && prev.properties.numericType == nil { starts.insert(i) }
        }
        return starts
    }

    private static func firstRange(of q: [Unicode.Scalar], in n: [Unicode.Scalar]) -> Int? {
        guard q.count <= n.count else { return nil }
        outer: for i in 0...(n.count - q.count) {
            for j in 0..<q.count where n[i + j] != q[j] { continue outer }
            return i
        }
        return nil
    }

    /// "as" matches "Aarav Sharma": each query char is the first letter of consecutive words.
    private static func isInitials(_ q: [Unicode.Scalar], starts: Set<Int>, n: [Unicode.Scalar]) -> Bool {
        let letters = starts.sorted().map { n[$0] }.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }
        guard q.count >= 2, q.count <= letters.count else { return false }
        return Array(letters.prefix(q.count)) == q
    }

    /// Every query word is a prefix of some distinct name word, in any order.
    private static func allWordsScore(_ query: String, _ name: String) -> Int? {
        var words = name.split(separator: " ").map(String.init)
        for token in query.split(separator: " ") {
            guard let i = words.firstIndex(where: { $0.hasPrefix(token) }) else { return nil }
            words.remove(at: i)
        }
        return allWords - min(name.count - query.count, 40)
    }

    /// Greedy subsequence with bonuses for word-start hits and consecutive runs, and a penalty for gaps.
    private static func subsequence(_ q: [Unicode.Scalar], _ n: [Unicode.Scalar], starts: Set<Int>) -> Int? {
        guard q.count >= 2 else { return nil }
        var qi = 0
        var score = 0
        var last = -1
        var firstHit = -1
        for (i, c) in n.enumerated() where qi < q.count {
            guard c == q[qi] else { continue }
            if firstHit < 0 { firstHit = i }
            var s = 10
            if starts.contains(i) { s += 25 }
            if last == i - 1 { s += 20 } else if last >= 0 { s -= min(i - last - 1, 10) }
            score += s
            last = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Scatter across a long name is a weak signal; require some structure for long queries.
        let perChar = score / q.count
        guard perChar >= 12 else { return nil }
        return min(subsequenceMax, 200 + score - min(firstHit, 20) - min(n.count - q.count, 40) / 4)
    }
}
