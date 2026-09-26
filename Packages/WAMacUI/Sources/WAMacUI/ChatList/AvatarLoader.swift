import CoreGraphics
import Foundation
import WAKit

/// Fills `ChatRowState.avatar` for rows as they are displayed. Cached decodes are synchronous;
/// misses decode off the main thread through `ThumbnailCache`; chats with no cached file ask
/// `AvatarService` once per session, and the resulting `avatarPath` arrives through the list observation.
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
        guard let path = state.avatarPath else {
            request(state.jid)
            return
        }
        if let hit = ThumbnailCache.shared.cached(key: path, maxPixelSize: Self.pixelSize) {
            state.avatar = hit
            return
        }
        Task { [weak state] in
            let image = await ThumbnailCache.shared.image(key: path, source: .file(URL(filePath: path)), maxPixelSize: Self.pixelSize)
            guard let state, state.avatarPath == path else { return }
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
