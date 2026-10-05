import Foundation
import Observation
import WAKit

enum CommandBarResult: Identifiable {
    case chat(RankedCandidate)
    case action(CommandAction)

    var id: String {
        switch self {
        case .chat(let r): "chat:" + r.id
        case .action(let a): "action:" + a.id
        }
    }
}

/// State behind the command bar: query, scope, merged chat/contact/action results, selection.
/// Candidate fetch and ranking run off the main actor; stale results are dropped by generation.
@Observable
@MainActor
final class CommandBarModel {
    private(set) var scope: QuickSearchScope = .all
    var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    private(set) var results: [CommandBarResult] = []
    var selectedIndex = 0
    /// Bumped whenever the search field should take focus.
    private(set) var focusRequest = 0
    private(set) var hasLoaded = false

    @ObservationIgnored let database: AppDatabase
    @ObservationIgnored let usage: QuickSearchUsageStore
    @ObservationIgnored let registry: CommandRegistry
    @ObservationIgnored private(set) var context = CommandContext()
    @ObservationIgnored var onOpenChat: ((QuickSearchCandidate) -> Void)?
    /// Called with the chosen action; the owner closes the bar, then performs it.
    @ObservationIgnored var onPerform: ((CommandAction) -> Void)?
    /// Closes the bar (mouse activation; keyboard activation is handled by the panel's key monitor).
    @ObservationIgnored var onDismissRequest: (() -> Void)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var appliedGeneration = 0
    /// Enter pressed before the latest keystroke's results arrived; activate when they do.
    @ObservationIgnored private var pendingActivation = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    nonisolated static let resultLimit = 40
    static let actionBaseline = 100.0
    /// An action whose title or keyword, or a word in it, starts with the query (allowing for the
    /// length penalty and the keyword discount) is listed above chats; weaker matches mix in by score.
    static let strongActionMatch = FuzzyMatcher.wordPrefix - 70

    init(database: AppDatabase, usage: QuickSearchUsageStore, registry: CommandRegistry) {
        self.database = database
        self.usage = usage
        self.registry = registry
    }

    var selected: CommandBarResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    var placeholder: String {
        scope == .contacts ? "Search contacts or enter a phone number" : "Search chats, contacts and actions"
    }

    func present(scope: QuickSearchScope, context: CommandContext) {
        self.scope = scope
        self.context = context
        if query.isEmpty { refresh() } else { query = "" }
        focusRequest += 1
    }

    func reset() {
        searchTask?.cancel()
        generation += 1
        query = ""
        results = []
        selectedIndex = 0
        hasLoaded = false
        pendingActivation = false
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
    }

    /// Activates the selection. Returns true when the bar should close.
    @discardableResult
    func activate(at index: Int? = nil) -> Bool {
        if let index {
            selectedIndex = index
        } else if appliedGeneration != generation {
            pendingActivation = true
            return false
        }
        guard let result = selected else { return false }
        switch result {
        case .chat(let ranked):
            usage.recordSelection(of: ranked.candidate.jid, query: query)
            onOpenChat?(ranked.candidate)
            return true
        case .action(let action):
            if action.id == "go.newChat" {
                present(scope: .contacts, context: context)
                return false
            }
            onPerform?(action)
            return true
        }
    }

    // MARK: Search

    func refresh() {
        searchTask?.cancel()
        generation += 1
        let gen = generation
        let query = query
        let scope = scope
        let usage = usage.usage
        let database = database
        let actions = scope == .all ? scoredActions(query) : []
        let direct = scope == .contacts ? directNumberCandidate(query) : nil

        searchTask = Task { [weak self] in
            let ranked: [RankedCandidate]
            do {
                ranked = try await Task.detached(priority: .userInitiated) {
                    let candidates = try await database.quickSearchCandidates(query: query, scope: scope)
                    return QuickSearchRanker.rank(candidates, query: query, usage: usage, limit: Self.resultLimit)
                }.value
            } catch {
                if !(error is CancellationError) { WAKit.log.error("command bar search failed: \(error)") }
                return
            }
            guard let self, gen == generation else { return }
            appliedGeneration = gen
            apply(ranked: ranked, actions: actions, direct: direct)
            if pendingActivation {
                pendingActivation = false
                if activate() { onDismissRequest?() }
            }
        }
    }

    private struct ScoredAction {
        let action: CommandAction
        let isChatAction: Bool
        /// Fuzzy match of the query; nil with nothing typed.
        let match: Int?
    }

    /// Actions first (the open chat's, then the rest; with a query only strong matches), then
    /// chats mixed by score with the weaker action matches.
    private func apply(ranked: [RankedCandidate], actions: [ScoredAction], direct: RankedCandidate?) {
        let isOnTop = { (a: ScoredAction) in a.match.map { $0 >= Self.strongActionMatch } ?? true }
        let top = actions.filter(isOnTop)
            .enumerated()
            .sorted { l, r in
                if l.element.isChatAction != r.element.isChatAction { return l.element.isChatAction }
                if l.element.match != r.element.match { return (l.element.match ?? 0) > (r.element.match ?? 0) }
                return l.offset < r.offset
            }
            .map { CommandBarResult.action($0.element.action) }
        var merged: [(CommandBarResult, Double)] = ranked.map { (.chat($0), $0.score) }
        merged += actions.filter { !isOnTop($0) }.map { (.action($0.action), Double($0.match ?? 0) + Self.actionBaseline) }
        merged.sort { $0.1 > $1.1 }
        var out = top + merged.prefix(Self.resultLimit).map(\.0)
        if let direct, !ranked.contains(where: { $0.candidate.jid == direct.candidate.jid }) {
            out.append(.chat(direct))
        }
        results = out
        selectedIndex = 0
        hasLoaded = true
    }

    /// With nothing typed, the open chat's actions; otherwise every action that matches.
    private func scoredActions(_ query: String) -> [ScoredAction] {
        let q = FuzzyMatcher.normalize(query)
        let grouped = registry.groupedActions(for: context)
        guard !q.isEmpty else {
            return grouped.filter { $0.group == .chat }.map { ScoredAction(action: $0.action, isChatAction: true, match: nil) }
        }
        return grouped.compactMap { action, group in
            FuzzyMatcher.best(q, title: FuzzyMatcher.normalize(action.title), alternates: action.keywords.map(FuzzyMatcher.normalize))
                .map { ScoredAction(action: action, isChatAction: group == .chat, match: $0) }
        }
    }

    /// ⌘N with a full phone number typed: offer to message that number even if it is not a contact.
    private func directNumberCandidate(_ query: String) -> RankedCandidate? {
        let digits = FuzzyMatcher.digits(query)
        let stripped = query.filter { !" +-().".contains($0) }
        guard digits.count >= 8, digits.count <= 15, stripped == digits else { return nil }
        let jid = digits + "@s.whatsapp.net"
        return RankedCandidate(candidate: QuickSearchCandidate(jid: jid, kind: .dm, title: PhoneFormat.display(digits), phone: digits, hasChat: false), score: 0)
    }
}
