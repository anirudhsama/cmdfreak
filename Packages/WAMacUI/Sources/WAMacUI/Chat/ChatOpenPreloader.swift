import Foundation
import Synchronization
import WAKit
import os

/// Everything the list needs for a synchronous first frame.
struct PreparedChat: @unchecked Sendable {
    let chatJid: String
    let chat: ChatRecord?
    let rows: ChatRows
    /// Plans keyed by message id, computed at `width`.
    let plans: [String: LayoutPlan]
    let width: CGFloat
    let ownJid: String?
}

/// Loads the first page and computes layout plans off the main thread. Call `prepare` (or `warm`)
/// as soon as a chat is about to open; `ChatViewController.show` consumes the result synchronously
/// through `takePrepared` so the first frame never waits on the database.
public actor ChatOpenPreloader {
    public static let shared = ChatOpenPreloader()

    public static let initialPageSize = 60

    private let ready = Mutex<[String: PreparedChat]>([:])
    private var inFlight: [String: Task<PreparedChat, any Error>] = [:]

    public init() {}

    /// Fire-and-forget warm-up (e.g. on hover or keyboard focus in the chat list).
    public nonisolated func warm(chatJid: String, width: CGFloat, client: WAClient) {
        Task(priority: .userInitiated) { _ = try? await self.prepare(chatJid: chatJid, width: width, client: client) }
    }

    /// Consumes a prepared payload if one exists for this chat and width. Synchronous, main-thread safe.
    nonisolated func takePrepared(chatJid: String, width: CGFloat) -> PreparedChat? {
        ready.withLock { store in
            guard let p = store[chatJid], abs(p.width - width) < 0.5 else { return nil }
            store[chatJid] = nil
            return p
        }
    }

    nonisolated func invalidate(chatJid: String) {
        ready.withLock { $0[chatJid] = nil }
    }

    @discardableResult
    func prepare(chatJid: String, width: CGFloat, client: WAClient) async throws -> PreparedChat {
        if let existing = ready.withLock({ $0[chatJid] }), abs(existing.width - width) < 0.5 { return existing }
        if let task = inFlight[chatJid] {
            let p = try await task.value
            if abs(p.width - width) < 0.5 { return p }
        }
        let task = Task.detached(priority: .userInitiated) {
            try Self.load(chatJid: chatJid, width: width, client: client)
        }
        inFlight[chatJid] = task
        defer { inFlight[chatJid] = nil }
        let prepared = try await task.value
        ready.withLock { $0[chatJid] = prepared }
        return prepared
    }

    /// Runs on a background thread: one DB read plus plan computation for the visible tail.
    static func load(chatJid: String, width: CGFloat, client: WAClient) throws -> PreparedChat {
        let state = Signposts.poi.beginInterval("ChatPreload", id: Signposts.poi.makeSignpostID())
        defer { Signposts.poi.endInterval("ChatPreload", state) }

        let loader = client.windowLoader(for: chatJid)
        let chat = try client.database.reader.read { db in try ChatRecord.fetchOne(db, key: chatJid) }
        let page = try loader.initialSync(limit: initialPageSize)
        var rows = ChatRows(chatJid: chatJid, isGroupChat: ChatKind(jid: chatJid) == .group)
        rows.replace(with: page)
        rows.setUnread(count: chat?.unreadCount ?? 0)

        let ownJid = client.ownJid
        let peerName = chat?.name
        var plans: [String: LayoutPlan] = [:]
        plans.reserveCapacity(rows.messages.count)
        let cache = LayoutPlanCache.shared
        for i in rows.messages.indices {
            let ctx = rows.context(forMessageAt: i, width: width, ownJid: ownJid, peerName: peerName)
            plans[rows.messages[i].id] = cache.plan(for: rows.messages[i], context: ctx)
        }
        // Warm the thumbnails the first frame will show.
        for item in rows.messages.suffix(20) {
            guard let media = item.media, let thumb = media.jpegThumbnail, !thumb.isEmpty else { continue }
            _ = ThumbnailCache.shared.decodeSync(key: LayoutPlanner.thumbKey(item), source: .data(thumb), maxPixelSize: 320)
        }
        return PreparedChat(chatJid: chatJid, chat: chat, rows: rows, plans: plans, width: width, ownJid: ownJid)
    }
}
