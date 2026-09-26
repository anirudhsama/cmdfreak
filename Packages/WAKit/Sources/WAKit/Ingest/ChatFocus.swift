import Synchronization

/// Which chat is open and whether its window is key. The UI sets it synchronously; `IngestActor`
/// reads it inside each transaction to decide whether an incoming message counts as unread.
public final class ChatFocus: Sendable {
    private let state = Mutex<(chatJid: String?, windowIsKey: Bool)>((nil, false))

    public init() {}

    public func set(chatJid: String?, windowIsKey: Bool) {
        state.withLock { $0 = (chatJid, windowIsKey) }
    }

    public var current: (chatJid: String?, windowIsKey: Bool) { state.withLock { $0 } }

    func isReading(_ chatJid: String) -> Bool {
        state.withLock { $0.chatJid == chatJid && $0.windowIsKey }
    }
}
