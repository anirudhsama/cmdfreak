import Foundation
import WAKit

/// The loaded message window as table rows. Pure value type: the preloader builds it off-main and
/// the list mutates it on the main actor.
struct ChatRows: Sendable {
    enum Row: Hashable, Sendable {
        /// Start of the day in unix seconds (local calendar).
        case day(Int64)
        case unread
        case message(String)
    }

    /// Index sets: `removed` indexes refer to the old rows, `inserted` and `reloaded` to the new rows.
    struct Update: Equatable, Sendable {
        var removed = IndexSet()
        var inserted = IndexSet()
        var reloaded = IndexSet()
        var reloadAll = false

        static let none = Update()
        static let all = Update(reloadAll: true)
        var isEmpty: Bool { !reloadAll && removed.isEmpty && inserted.isEmpty && reloaded.isEmpty }
    }

    let chatJid: String
    let isGroupChat: Bool
    private(set) var messages: [MessageItem] = []  // ascending by sortKey
    private(set) var rows: [Row] = []
    private(set) var messageIndex: [String: Int] = [:]
    private(set) var rowIndex: [String: Int] = [:]
    /// Sender display names seen in the loaded window (groups), for quoted-reply headers.
    private(set) var senderNames: [String: String] = [:]
    var hasOlder = false
    var hasNewer = false
    /// The first unread message; the unread separator sits before it.
    var unreadFirstId: String?

    init(chatJid: String, isGroupChat: Bool) {
        self.chatJid = chatJid
        self.isGroupChat = isGroupChat
    }

    var count: Int { rows.count }
    var oldestSortKey: Int64? { messages.first?.sortKey }
    var newestSortKey: Int64? { messages.last?.sortKey }

    func row(at i: Int) -> Row? { rows.indices.contains(i) ? rows[i] : nil }

    func item(id: String) -> MessageItem? { messageIndex[id].map { messages[$0] } }

    func item(atRow i: Int) -> MessageItem? {
        guard case .message(let id) = row(at: i) else { return nil }
        return item(id: id)
    }

    /// WhatsApp accepts edits for 15 minutes after sending.
    static let editWindowSeconds: Int64 = 15 * 60

    /// Own, sent text messages inside the edit window.
    static func canEdit(_ item: MessageItem, now: Int64 = Int64(Date().timeIntervalSince1970)) -> Bool {
        let m = item.message
        return m.fromMe && m.kind == .text && !m.revoked && !m.isPending && m.status != .failed
            && now - m.timestamp <= editWindowSeconds
    }

    /// Reply and react targets: anything delivered that is not a system notice or deleted.
    static func canRespond(to item: MessageItem) -> Bool {
        let m = item.message
        return !m.revoked && m.kind != .system && !m.isPending
    }

    // MARK: - Grouping

    private static let groupGapSeconds: Int64 = 10 * 60

    private func sameRun(_ a: MessageItem, _ b: MessageItem) -> Bool {
        guard a.message.kind != .system, b.message.kind != .system else { return false }
        guard a.message.fromMe == b.message.fromMe, a.message.senderJid == b.message.senderJid else { return false }
        guard Self.dayStart(a.message.timestamp) == Self.dayStart(b.message.timestamp) else { return false }
        return abs(a.message.timestamp - b.message.timestamp) <= Self.groupGapSeconds
    }

    func context(forMessageAt i: Int, width: CGFloat, ownJid: String?, peerName: String?) -> RowContext {
        let item = messages[i]
        let prev = i > 0 ? messages[i - 1] : nil
        let next = i + 1 < messages.count ? messages[i + 1] : nil
        let first = prev.map { !sameRun($0, item) } ?? true
        let last = next.map { !sameRun(item, $0) } ?? true
        // A separator between two messages breaks the run visually as well.
        let firstWithSeparator = first || (unreadFirstId == item.id)
        return RowContext(
            width: width, isGroupChat: isGroupChat, showsSender: isGroupChat && firstWithSeparator,
            isFirstInGroup: firstWithSeparator, isLastInGroup: last || (next.map { unreadFirstId == $0.id } ?? false),
            ownJid: ownJid, peerName: peerName,
            quotedSenderName: item.message.quotedSenderJid.flatMap { senderNames[$0] })
    }

    static func dayStart(_ ts: Int64) -> Int64 {
        Int64(Calendar.autoupdatingCurrent.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts))).timeIntervalSince1970)
    }

    // MARK: - Mutation

    /// Replaces the window (initial page, `around`, reload).
    mutating func replace(with page: MessagePage) {
        messages = page.items
        hasOlder = page.hasOlder
        hasNewer = page.hasNewer
        rebuild()
    }

    /// Marks the first of the newest `unreadCount` incoming messages so the separator can be shown.
    mutating func setUnread(count: Int) {
        guard count > 0 else { unreadFirstId = nil; rebuild(); return }
        var remaining = count
        var firstId: String?
        for item in messages.reversed() where !item.message.fromMe && item.message.kind != .system {
            firstId = item.id
            remaining -= 1
            if remaining == 0 { break }
        }
        unreadFirstId = firstId
        rebuild()
    }

    mutating func prepend(_ page: MessagePage) -> Update {
        hasOlder = page.hasOlder
        let known = Set(messages.map(\.id))
        let fresh = page.items.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return .none }
        return transition { $0 = fresh + $0 }
    }

    mutating func append(_ page: MessagePage) -> Update {
        hasNewer = page.hasNewer
        let known = Set(messages.map(\.id))
        let fresh = page.items.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return .none }
        return transition { $0 += fresh }
    }

    mutating func apply(_ change: MessageChange) -> Update {
        switch change {
        case .reload:
            return .all
        case .delete(let ids):
            let gone = Set(ids)
            guard messages.contains(where: { gone.contains($0.id) }) else { return .none }
            return transition { $0.removeAll { gone.contains($0.id) } }
        case .replace(let oldId, let item):
            guard let i = messageIndex[oldId] else { return apply(.add([item])) }
            return transition { $0[i] = item }
        case .update(let items):
            var touched: [String] = []
            var moved = false
            for item in items {
                guard let i = messageIndex[item.id] else { continue }
                if messages[i].sortKey != item.sortKey { moved = true }
                messages[i] = item
                touched.append(item.id)
            }
            guard !touched.isEmpty else { return .none }
            if moved { return transition { _ in } }
            var update = Update()
            for id in touched { if let r = rowIndex[id] { update.reloaded.insert(r) } }
            return update
        case .add(let items):
            var adds: [MessageItem] = []
            var updates: [MessageItem] = []
            for item in items {
                if messageIndex[item.id] != nil { updates.append(item) } else { adds.append(item) }
            }
            var update = Update()
            if !updates.isEmpty { update = apply(.update(updates)) }
            guard !adds.isEmpty else { return update }
            // Ignore back-fill outside the loaded window when more pages exist on that side.
            let inWindow = adds.filter { a in
                if let oldest = oldestSortKey, a.sortKey < oldest, hasOlder { return false }
                if let newest = newestSortKey, a.sortKey > newest, hasNewer { return false }
                return true
            }
            guard !inWindow.isEmpty else { return update }
            let t = transition {
                $0 += inWindow
                $0.sort { $0.sortKey < $1.sortKey }
            }
            if update.reloadAll || t.reloadAll { return .all }
            var merged = t
            merged.reloaded.formUnion(update.reloaded)
            return merged
        }
    }

    // MARK: - Diffing

    /// Runs `mutate` on `messages` and diffs old rows against new rows. Rows are unique and both
    /// sequences are ordered by sortKey, so a set diff yields consistent remove/insert index sets.
    private mutating func transition(_ mutate: (inout [MessageItem]) -> Void) -> Update {
        let oldRows = rows
        let oldMessages = messages
        let oldIndex = messageIndex
        mutate(&messages)
        rebuild()
        let oldSet = Set(oldRows)
        let newSet = Set(rows)
        var update = Update()
        for (i, r) in oldRows.enumerated() where !newSet.contains(r) { update.removed.insert(i) }
        for (i, r) in rows.enumerated() where !oldSet.contains(r) { update.inserted.insert(i) }
        // Neighbours of inserted/removed messages may have changed grouping (tail, sender name).
        var neighbours = Set<String>()
        for i in update.inserted {
            if case .message(let id) = rows[i], let mi = messageIndex[id] {
                if mi > 0 { neighbours.insert(messages[mi - 1].id) }
                if mi + 1 < messages.count { neighbours.insert(messages[mi + 1].id) }
            }
        }
        for i in update.removed {
            if case .message(let id) = oldRows[i], let mi = oldIndex[id] {
                if mi > 0 { neighbours.insert(oldMessages[mi - 1].id) }
                if mi + 1 < oldMessages.count { neighbours.insert(oldMessages[mi + 1].id) }
            }
        }
        // Content changes on rows that survived (replace / moved update).
        for (id, ni) in messageIndex {
            if let oi = oldIndex[id], oldMessages[oi] != messages[ni] { neighbours.insert(id) }
        }
        for id in neighbours {
            if let r = rowIndex[id], !update.inserted.contains(r) { update.reloaded.insert(r) }
        }
        return update
    }

    private mutating func rebuild() {
        var out: [Row] = []
        out.reserveCapacity(messages.count + 8)
        var mIndex: [String: Int] = [:]
        var rIndex: [String: Int] = [:]
        mIndex.reserveCapacity(messages.count)
        rIndex.reserveCapacity(messages.count)
        var prevDay: Int64?
        var names: [String: String] = [:]
        for (i, item) in messages.enumerated() {
            if isGroupChat, !item.message.fromMe, let n = item.senderName { names[item.message.senderJid] = n }
            let day = Self.dayStart(item.message.timestamp)
            if day != prevDay {
                out.append(.day(day))
                prevDay = day
            }
            if item.id == unreadFirstId { out.append(.unread) }
            mIndex[item.id] = i
            rIndex[item.id] = out.count
            out.append(.message(item.id))
        }
        rows = out
        messageIndex = mIndex
        rowIndex = rIndex
        senderNames = names
    }
}
