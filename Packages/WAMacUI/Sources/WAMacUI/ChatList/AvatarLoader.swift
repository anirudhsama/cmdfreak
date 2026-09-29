import CoreGraphics
import Foundation
import WAKit

/// Loads avatars for chat rows and group senders. Cached decodes are synchronous; misses decode off
/// the main thread through `ThumbnailCache`, keyed by the file's modification time so a picture saved
/// over an old one is decoded again. JIDs are sent to `AvatarService` in batches. Chat rows are asked
/// about once per session, or again through `reload` when the list observation reports a change;
/// group senders have no observation, so theirs are asked again after `senderRecheck` (answered from
/// the service's record unless the picture changed) and reported through `onSenderAvatar`.
@MainActor
final class AvatarLoader {
    static let senderRecheck: Duration = .seconds(60)

    private struct Sender {
        /// Nil: none, or hidden from us.
        var file: URL?
        var resolvedAt: ContinuousClock.Instant
    }

    private let avatars: AvatarService
    private let pixelSize: Int
    /// Chat rows asked about this session; senders queued or in flight.
    private var requested: Set<String> = []
    private var pending: [(jid: String, group: String?)] = []
    private var flushScheduled = false
    /// The file `AvatarService` resolved per sender (a LID's is its phone number's).
    private var senders: [String: Sender] = [:]
    /// Decode key → senders waiting on it.
    private var decoding: [String: Set<String>] = [:]
    /// A group sender's picture loaded, changed or went away; ask `senderAvatar` again.
    var onSenderAvatar: ((String) -> Void)?

    init(avatars: AvatarService, pixelSize: Int) {
        self.avatars = avatars
        self.pixelSize = pixelSize
    }

    func load(_ state: ChatRowState) {
        guard state.avatar == nil else { return }
        guard let url = state.avatarURL else {
            request(state.jid)
            return
        }
        if let key = ThumbnailCache.fileKey(url), let hit = ThumbnailCache.shared.cached(key: key, maxPixelSize: pixelSize) {
            state.avatar = hit
            return
        }
        let avatars = self.avatars, pixelSize = self.pixelSize
        Task { [weak state] in
            // A recorded file purged from Caches is fetched again first.
            if ThumbnailCache.fileKey(url) == nil, let jid = state?.jid { _ = await avatars.avatar(for: jid) }
            guard let key = ThumbnailCache.fileKey(url) else { return }
            let image = await ThumbnailCache.shared.image(key: key, source: .file(url), maxPixelSize: pixelSize)
            guard let state, state.avatarURL == url else { return }
            state.avatar = image
        }
    }

    /// The row's picture was fetched, changed or removed: load it again, asking `AvatarService` even
    /// if this session already has.
    func reload(_ state: ChatRowState) {
        requested.remove(state.jid)
        load(state)
    }

    /// `jid`'s picture if decoded; otherwise nil, with `onSenderAvatar` to follow once it is. Until
    /// `AvatarService` has answered, a file already on disk shows straight away.
    func senderAvatar(_ jid: String, group: String) -> CGImage? {
        let sender = senders[jid]
        if sender.map({ ContinuousClock.now - $0.resolvedAt > Self.senderRecheck }) ?? true { request(jid, group: group) }
        let url = if let sender { sender.file } else { AvatarService.fileURL(for: jid) }
        guard let url, let key = ThumbnailCache.fileKey(url) else { return nil }
        if let hit = ThumbnailCache.shared.cached(key: key, maxPixelSize: pixelSize) { return hit }
        decode(jid, url, key)
        return nil
    }

    private func decode(_ jid: String, _ url: URL, _ key: String) {
        guard decoding[key] == nil else {
            decoding[key]?.insert(jid)
            return
        }
        decoding[key] = [jid]
        let pixelSize = self.pixelSize
        Task { [weak self] in
            let image = await ThumbnailCache.shared.image(key: key, source: .file(url), maxPixelSize: pixelSize)
            guard let self, let waiting = decoding.removeValue(forKey: key), image != nil else { return }
            for jid in waiting { onSenderAvatar?(jid) }
        }
    }

    private func senderResolved(_ jid: String, _ url: URL?) {
        requested.remove(jid)
        senders[jid] = Sender(file: url, resolvedAt: .now)
        if let url, let key = ThumbnailCache.fileKey(url), ThumbnailCache.shared.cached(key: key, maxPixelSize: pixelSize) == nil {
            decode(jid, url, key)
        } else {
            onSenderAvatar?(jid)
        }
    }

    private func request(_ jid: String, group: String? = nil) {
        guard requested.insert(jid).inserted else { return }
        pending.append((jid, group))
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        let batch = pending
        pending.removeAll()
        let avatars = self.avatars
        Task.detached(priority: .utility) { [weak self] in
            for (jid, group) in batch {
                let url = await avatars.avatar(for: jid, commonGroup: group)
                if group != nil { await self?.senderResolved(jid, url) }
            }
        }
    }
}
