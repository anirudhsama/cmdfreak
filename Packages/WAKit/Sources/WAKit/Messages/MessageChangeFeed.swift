import Foundation
import Synchronization

/// A committed change to one chat's messages, published by `IngestActor` after each transaction.
/// The open chat view applies these to its window instead of re-querying (Inline's MessagesPublisher).
public enum MessageChange: Sendable, Hashable {
    /// New rows, ascending by `sortKey`. They may fall anywhere in the timeline (history back-fill),
    /// so place them by `sortKey` and ignore those outside the loaded window.
    case add([MessageItem])
    /// Existing rows whose content changed (edit, revoke, reaction, status, media state).
    case update([MessageItem])
    case delete(ids: [String])
    /// An optimistic row got its server id; same position.
    case replace(oldId: String, item: MessageItem)
    /// The window must be reloaded (alias merge, clear, large back-fill).
    case reload

    public var ids: [String] {
        switch self {
        case .add(let items), .update(let items): items.map(\.id)
        case .delete(let ids): ids
        case .replace(_, let item): [item.id]
        case .reload: []
        }
    }
}

/// Per-chat fan-out of `MessageChange`s. Ordered delivery through `AsyncStream`.
public final class MessageChangeFeed: Sendable {
    private struct Subscriber {
        let chatJid: String
        let continuation: AsyncStream<MessageChange>.Continuation
    }

    private let subscribers = Mutex<[UUID: Subscriber]>([:])

    public init() {}

    /// Changes for `chatJid`. Iterate on the main actor; cancel the iterating task to unsubscribe.
    public func changes(for chatJid: String) -> AsyncStream<MessageChange> {
        let (stream, continuation) = AsyncStream<MessageChange>.makeStream(bufferingPolicy: .unbounded)
        let token = UUID()
        subscribers.withLock { $0[token] = Subscriber(chatJid: chatJid, continuation: continuation) }
        continuation.onTermination = { [weak self] _ in
            _ = self?.subscribers.withLock { $0.removeValue(forKey: token) }
        }
        return stream
    }

    /// Chats that currently have at least one subscriber. Only these get rows loaded after commit.
    var observedChats: Set<String> {
        subscribers.withLock { Set($0.values.map(\.chatJid)) }
    }

    func publish(_ change: MessageChange, chatJid: String) {
        let targets = subscribers.withLock { $0.values.filter { $0.chatJid == chatJid }.map(\.continuation) }
        for c in targets { c.yield(change) }
    }
}
