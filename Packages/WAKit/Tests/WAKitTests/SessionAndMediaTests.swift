import Foundation
import Testing
@testable import WAKit

@MainActor @Suite struct SessionServiceTests {
    @Test func pairingFlowToReady() {
        let bridge = FakeBridge()
        let s = SessionService(bridge: bridge, ownJid: nil)
        #expect(s.state == .unpaired)
        s.handle(.pairing(.qr(code: "2@abc", timeoutSecs: 20)))
        #expect(s.state == .pairing(.qr("2@abc")))
        s.handle(.pairing(.pairCode(code: "ABCD-1234", timeoutSecs: 180)))
        #expect(s.state == .pairing(.code("ABCD-1234")))
        s.handle(.pairing(.success(jid: F.me, pushName: "Me")))
        #expect(s.ownJid == F.me)
        #expect(!s.canShowMainWindow)
        s.handle(.history(syncType: .initialBootstrap, progress: nil, chats: 40, messages: 900, isLastInPayload: true))
        #expect(s.canShowMainWindow)
        guard case .syncing(let p) = s.state else { Issue.record("expected syncing"); return }
        #expect(p.conversations == 40 && p.messages == 900)
        s.handle(.history(syncType: .recent, progress: 100, chats: 10, messages: 100, isLastInPayload: true))
        #expect(s.state == .ready)
        s.handle(.pairing(.loggedOut(reason: "removed")))
        #expect(s.state == .loggedOut(reason: "removed"))
    }

    @Test func pairedLaunchStartsReadyAndTracksConnection() {
        let s = SessionService(bridge: FakeBridge(), ownJid: F.me)
        #expect(s.state == .ready)
        s.handle(.connection(.connected))
        #expect(s.connection == .connected)
        s.handle(.history(syncType: .recent, progress: 40, chats: 5, messages: 50, isLastInPayload: false))
        #expect(s.backgroundSync?.percent == 40)
        #expect(s.state == .ready)
    }

    @Test func wakeNudgesReconnect() async throws {
        let bridge = FakeBridge()
        let s = SessionService(bridge: bridge, ownJid: F.me)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(bridge.calls.withLock { $0.nudges } == 1)
        _ = s
    }
}

import AppKit

@Suite struct MediaStoreTests {
    func store(_ bridge: FakeBridge, ingest: IngestActor? = nil) async -> MediaStore {
        let root = FileManager.default.temporaryDirectory.appending(path: "wakit-media-\(UUID().uuidString)")
        return await MediaStore(bridge: bridge, ingest: ingest, root: root) { src, dst in
            try FileManager.default.copyItem(atPath: src, toPath: dst)
        }
    }

    @Test func concurrentDownloadsAreDeduplicated() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(F.message("img", chat: F.bob, kind: .image, media: F.media(sha: 9)))])
        let media = try #require(try await ChatWindowLoader(database: db, chatJid: F.bob).initial().items.first?.media)

        let bridge = FakeBridge()
        let store = await store(bridge, ingest: ingest)
        async let a = store.download(media)
        async let b = store.download(media)
        async let c = store.download(media)
        let urls = try await [a, b, c]
        #expect(Set(urls).count == 1)
        #expect(bridge.calls.withLock { $0.downloads } == 1)
        #expect(urls[0].lastPathComponent == Data(repeating: 9, count: 32).hexString + ".jpeg")
        #expect(store.localURL(for: media) != nil)
        _ = try await store.download(media)
        #expect(bridge.calls.withLock { $0.downloads } == 1)

        let row = try #require(try await ChatWindowLoader(database: db, chatJid: F.bob).initial().items.first?.media)
        #expect(row.downloadState == .downloaded && row.localPath == urls[0].path)
    }

    @Test func voiceNotesRemuxedNextToOriginal() async throws {
        let bridge = FakeBridge()
        let store = await store(bridge)
        let media = IngestActor.mediaRecord(F.media(sha: 3, type: .audio, mimetype: "audio/ogg; codecs=opus"), chatJid: F.bob, messageId: "v")
        let url = try await store.playableAudioURL(media)
        #expect(url.pathExtension == "caf")
        #expect(FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("ogg").path))
    }

    @Test func autoDownloadPolicy() {
        let small = IngestActor.mediaRecord(F.media(length: 1_000_000), chatJid: F.bob, messageId: "a")
        let big = IngestActor.mediaRecord(F.media(length: 20_000_000), chatJid: F.bob, messageId: "b")
        #expect(MediaStore.shouldAutoDownload(kind: .image, media: small))
        #expect(MediaStore.shouldAutoDownload(kind: .voice, media: small))
        #expect(MediaStore.shouldAutoDownload(kind: .gif, media: small))
        #expect(MediaStore.shouldAutoDownload(kind: .sticker, media: small))
        #expect(!MediaStore.shouldAutoDownload(kind: .image, media: big))
        #expect(!MediaStore.shouldAutoDownload(kind: .video, media: small))
        #expect(!MediaStore.shouldAutoDownload(kind: .document, media: small))
    }

    @Test func thumbnailsDecodeAtDisplaySize() async throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let cache = ThumbnailCache()
        #expect(cache.cached(key: "k", maxPixelSize: 100) == nil)
        let img = try #require(await cache.image(key: "k", source: .data(png), maxPixelSize: 100))
        #expect(img.width == 100 && img.height == 50)
        #expect(cache.cached(key: "k", maxPixelSize: 100) != nil)
    }

    @Test func avatarsCachedAndRecorded() async throws {
        let db = try F.tempDB()
        let ingest = try IngestActor(database: db)
        try await ingest.apply([F.live(F.message("a", chat: F.bob))])
        let root = FileManager.default.temporaryDirectory.appending(path: "wakit-avatars-\(UUID().uuidString)")
        let avatars = AvatarService(bridge: FakeBridge(), ingest: ingest, root: root)
        let url = try #require(await avatars.avatar(for: F.bob))
        #expect(try db.chat(F.bob)?.avatarPath == url.path)
        try await ingest.apply([.pictureChanged(jid: F.bob)])
        #expect(try db.chat(F.bob)?.avatarPath == nil)
    }
}
