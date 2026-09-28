import CoreGraphics
import Foundation
import WAKit

/// Fills `ChatRowState.avatar` for rows as they are displayed. Cached decodes are synchronous;
/// misses decode off the main thread through `ThumbnailCache`; chats with no cached file ask
/// `AvatarService` once per session, and the resulting `hasAvatar` arrives through the list
/// observation. A recorded file that fails to load (purged from Caches) is fetched again.
@MainActor
final class AvatarLoader {
    static let pixelSize = Int(ChatRowMetrics.avatarSize) * 2

    private let avatars: AvatarService
    private var requested: Set<String> = []
    private var pending: [String] = []
    private var flushScheduled = false

    init(avatars: AvatarService) {
        self.avatars = avatars
    }

    func load(_ state: ChatRowState) {
        guard state.avatar == nil else { return }
        guard let url = state.avatarURL else {
            request(state.jid)
            return
        }
        if let hit = ThumbnailCache.shared.cached(key: url.path, maxPixelSize: Self.pixelSize) {
            state.avatar = hit
            return
        }
        let avatars = self.avatars
        Task { [weak state] in
            var image = await ThumbnailCache.shared.image(key: url.path, source: .file(url), maxPixelSize: Self.pixelSize)
            if image == nil, let jid = state?.jid, await avatars.avatar(for: jid) != nil {
                image = await ThumbnailCache.shared.image(key: url.path, source: .file(url), maxPixelSize: Self.pixelSize)
            }
            guard let state, state.avatarURL == url else { return }
            state.avatar = image
        }
    }

    private func request(_ jid: String) {
        guard requested.insert(jid).inserted else { return }
        pending.append(jid)
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
        Task.detached(priority: .utility) {
            for jid in batch { _ = await avatars.avatar(for: jid) }
        }
    }
}
