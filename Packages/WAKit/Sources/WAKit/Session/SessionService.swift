import AppKit
import Foundation
import Observation

/// Session-relevant slice of a bridge event, small enough to hop to the main actor.
public enum SessionEvent: Sendable, Hashable {
    case connection(BridgeConnection)
    case pairing(BridgePairing)
    case history(syncType: HistorySyncType, progress: UInt32?, chats: Int, messages: Int, isLastInPayload: Bool)
    case offlineSyncCompleted
    case ownJid(pn: String?, lid: String?)

    init?(_ event: BridgeEvent) {
        switch event {
        case .connection(let s): self = .connection(s)
        case .pairing(let s): self = .pairing(s)
        case .historyChunk(let c):
            self = .history(syncType: c.syncType, progress: c.progress, chats: c.chats.count,
                            messages: c.messages.count, isLastInPayload: c.isLastInPayload)
        case .offlineSyncCompleted: self = .offlineSyncCompleted
        case .ownJid(let pn, let lid): self = .ownJid(pn: pn, lid: lid)
        default: return nil
        }
    }
}

/// Connection and pairing state for the UI. Reconnection belongs to the Rust library; this only
/// nudges it on system wake.
@MainActor @Observable
public final class SessionService {
    public enum Pairing: Hashable, Sendable {
        case qr(String)
        case code(String)
    }

    public struct SyncProgress: Hashable, Sendable {
        public var percent: Int?
        public var chunks = 0
        public var conversations = 0
        public var messages = 0
    }

    public enum State: Hashable, Sendable {
        case unpaired
        case pairing(Pairing)
        case syncing(SyncProgress)
        case ready
        case loggedOut(reason: String)
    }

    public private(set) var state: State
    public private(set) var connection: BridgeConnection = .disconnected(reason: "")
    public private(set) var ownJid: String?
    public private(set) var ownLid: String?
    public private(set) var pairingError: String?
    /// Background history sync after `ready` (RECENT/FULL chunks keep arriving for minutes).
    public private(set) var backgroundSync: SyncProgress?

    /// The main window can show once the first history chunk has landed.
    public var canShowMainWindow: Bool {
        switch state {
        case .ready: true
        case .syncing(let p): p.chunks > 0
        default: false
        }
    }

    @ObservationIgnored private let bridge: (any WaBridgeProtocol)?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    public init(bridge: (any WaBridgeProtocol)?, ownJid: String?) {
        self.bridge = bridge
        self.ownJid = ownJid
        state = ownJid == nil ? .unpaired : .ready
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [bridge] _ in
            bridge?.nudgeReconnect()
        }
    }

    isolated deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    public func handle(_ events: [SessionEvent]) {
        for e in events { handle(e) }
    }

    public func handle(_ event: SessionEvent) {
        switch event {
        case .connection(let c):
            connection = c
        case .pairing(.qr(let code, _)):
            pairingError = nil
            state = .pairing(.qr(code))
        case .pairing(.pairCode(let code, _)):
            pairingError = nil
            state = .pairing(.code(code))
        case .pairing(.success(let jid, _)):
            ownJid = jid
            pairingError = nil
            state = .syncing(SyncProgress())
        case .pairing(.error(let message)):
            pairingError = message
        case .pairing(.loggedOut(let reason)):
            ownJid = nil
            ownLid = nil
            backgroundSync = nil
            state = .loggedOut(reason: reason)
        case .ownJid(let pn, let lid):
            if let pn { ownJid = pn }
            if let lid { ownLid = lid }
            if state == .unpaired { state = .ready }
        case .history(let type, let progress, let chats, let messages, let isLast):
            let finished = isLast && (progress ?? 0) >= 100 && (type == .recent || type == .full)
            if case .syncing(var p) = state {
                p.chunks += 1
                p.conversations += chats
                p.messages += messages
                if let progress { p.percent = Int(progress) }
                state = finished ? .ready : .syncing(p)
            } else if state == .ready {
                var p = backgroundSync ?? SyncProgress()
                p.chunks += 1
                p.conversations += chats
                p.messages += messages
                if let progress { p.percent = Int(progress) }
                backgroundSync = finished ? nil : p
            }
        case .offlineSyncCompleted:
            if case .syncing(let p) = state, p.chunks > 0 { state = .ready }
        }
    }
}
