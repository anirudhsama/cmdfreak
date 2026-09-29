import CoreGraphics
import Foundation
import WAKit

/// Loads avatars for chat rows and group senders. Cached decodes are synchronous; misses decode off
/// the main thread through `ThumbnailCache`, keyed by the file's modification time so a picture saved
/// over an old one is decoded again. JIDs are sent to `AvatarService` in batches, each at most once
/// per session. Chat rows pick up the result through the list observation (`hasAvatar`); group
/// senders have none, so `onSenderAvatar` reports theirs. A recorded file that fails to load (purged
/// from Caches) is fetched again.
@MainActor
final class AvatarLoader {
    private let avatars: AvatarService
    private let pixelSize: Int
    private var requested: Set<String> = []
    private var pending: [(jid: String, group: String?)] = []
    private var flushScheduled = false
    /// Group sender → the file `AvatarService` resolved (a LID's is its phone number's).
    private var senderFiles: [String: URL] = [:]
    private var decoding: Set<String> = []
    /// A group sender's image is ready; ask `senderAvatar` again.
    var onSenderAvatar: ((String) -> Void)?

    init(avatars: AvatarService, pixelSize: Int) {
        self.avatars = avatars
        self.pixelSize = pixelSize
    }

    func load(_ state: ChatRowState) {
        guard state.avatar == nil else { return }
        guard let url = state.avatarURL, let key = ThumbnailCache.fileKey(url) else {
            request(state.jid)
            return
        }
        if let hit = ThumbnailCache.shared.cached(key: key, maxPixelSize: pixelSize) {
            state.avatar = hit
            return
        }
        let avatars = self.avatars, pixelSize = self.pixelSize
        Task { [weak state] in
            var image = await ThumbnailCache.shared.image(key: key, source: .file(url), maxPixelSize: pixelSize)
            if image == nil, let jid = state?.jid, await avatars.avatar(for: jid) != nil, let key = ThumbnailCache.fileKey(url) {
                image = await ThumbnailCache.shared.image(key: key, source: .file(url), maxPixelSize: pixelSize)
            }
            guard let state, state.avatarURL == url else { return }
            state.avatar = image
        }
    }

    /// `jid`'s picture if decoded; otherwise nil, with `onSenderAvatar` to follow once it is. A file
    /// already on disk shows straight away; `AvatarService` is still asked, in `group`, which it
    /// answers from its record unless the picture changed or was never checked.
    func senderAvatar(_ jid: String, group: String) -> CGImage? {
        request(jid, group: group)
        let url = senderFiles[jid] ?? AvatarService.fileURL(for: jid)
        guard let key = ThumbnailCache.fileKey(url) else { return nil }
        if let hit = ThumbnailCache.shared.cached(key: key, maxPixelSize: pixelSize) { return hit }
        decode(jid, url, key)
        return nil
    }

    private func decode(_ jid: String, _ url: URL, _ key: String) {
        guard decoding.insert(key).inserted else { return }
        let pixelSize = self.pixelSize
        Task { [weak self] in
            let image = await ThumbnailCache.shared.image(key: key, source: .file(url), maxPixelSize: pixelSize)
            guard let self else { return }
            decoding.remove(key)
            if image != nil { onSenderAvatar?(jid) }
        }
    }

    private func senderResolved(_ jid: String, _ url: URL) {
        senderFiles[jid] = url
        guard let key = ThumbnailCache.fileKey(url) else { return }
        if ThumbnailCache.shared.cached(key: key, maxPixelSize: pixelSize) != nil {
            onSenderAvatar?(jid)
        } else {
            decode(jid, url, key)
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
                if group != nil, let url { await self?.senderResolved(jid, url) }
            }
        }
    }
}
