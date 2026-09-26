import Foundation
import Observation
import Synchronization
import UniformTypeIdentifiers
import os

/// Download progress for in-flight media, keyed by `MediaStore.key(for:)`. Observe from the UI.
@MainActor @Observable
public final class MediaProgressCenter {
    public private(set) var fractions: [String: Double] = [:]

    public init() {}

    public func fraction(for media: MediaRecord) -> Double? { fractions[MediaStore.key(for: media)] }

    func set(_ key: String, _ fraction: Double?) { fractions[key] = fraction }

    /// FIFO hop to the main queue so a late progress tick can never land after the completion reset.
    nonisolated func post(_ key: String, _ fraction: Double?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.set(key, fraction) } }
    }
}

/// Content-addressed media cache under `~/Library/Caches/BetterWA/media/`, keyed by `fileSha256`.
/// Concurrent requests for the same file share one download.
public actor MediaStore {
    public static let autoDownloadLimit: Int64 = 16 * 1024 * 1024

    public nonisolated let root: URL
    public nonisolated let progress: MediaProgressCenter
    private let bridge: any WaBridgeProtocol
    private let ingest: IngestActor?
    private let remux: @Sendable (String, String) throws -> Void
    private var inFlight: [String: Task<URL, any Error>] = [:]

    public static var defaultRoot: URL {
        URL.cachesDirectory.appending(path: "BetterWA/media", directoryHint: .isDirectory)
    }

    @MainActor
    public init(
        bridge: any WaBridgeProtocol,
        ingest: IngestActor?,
        root: URL = MediaStore.defaultRoot,
        remux: @escaping @Sendable (String, String) throws -> Void = { try remuxOggToCaf(src: $0, dst: $1) }
    ) {
        self.bridge = bridge
        self.ingest = ingest
        self.root = root
        self.remux = remux
        self.progress = MediaProgressCenter()
    }

    // MARK: Paths

    public nonisolated static func key(for media: MediaRecord) -> String {
        media.fileSha256.isEmpty ? "\(media.chatJid)/\(media.messageId)" : media.fileSha256.hexString
    }

    /// Where the decrypted file lives (or will live). Pending outgoing media points at its source file.
    public nonisolated func fileURL(for media: MediaRecord) -> URL {
        if media.fileSha256.isEmpty, let p = media.localPath { return URL(filePath: p) }
        let hex = media.fileSha256.hexString
        return root.appending(path: String(hex.prefix(2)), directoryHint: .isDirectory)
            .appending(path: "\(hex).\(Self.fileExtension(for: media))")
    }

    /// The local file if already downloaded. Does a file-system check; keep it out of cell code.
    public nonisolated func localURL(for media: MediaRecord) -> URL? {
        let url = fileURL(for: media)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated static func fileExtension(for media: MediaRecord) -> String {
        if let name = media.fileName, let ext = name.split(separator: ".").last, ext.count <= 8, name.contains(".") {
            return String(ext).lowercased()
        }
        let mime = media.mimetype?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
        if let mime, mime.hasPrefix("audio/ogg") { return "ogg" }
        if let mime, let ext = UTType(mimeType: mime)?.preferredFilenameExtension { return ext }
        switch media.mediaType {
        case .image: return "jpg"
        case .video: return "mp4"
        case .audio: return "ogg"
        case .sticker: return "webp"
        case .document: return "bin"
        }
    }

    // MARK: Policy

    /// Images, stickers, GIFs and voice notes up to 16 MB download without a click.
    public nonisolated static func shouldAutoDownload(kind: MessageKind, media: MediaRecord) -> Bool {
        switch kind {
        case .image, .sticker, .gif, .voice: media.fileLength <= autoDownloadLimit
        default: false
        }
    }

    /// Call from the visible-row warm-up; no-op when not eligible or already present.
    public func autoDownloadIfNeeded(_ item: MessageItem) {
        guard let media = item.media, !item.message.revoked else { return }
        if media.downloadState != .downloaded, let url = localURL(for: media) {
            // The file is already cached (re-sync, fresh database): record it so cells can show it.
            Task { await self.recordExisting(url, for: media) }
            return
        }
        guard Self.shouldAutoDownload(kind: item.message.kind, media: media),
              !media.directPath.isEmpty, localURL(for: media) == nil else { return }
        Task { _ = try? await self.download(media) }
    }

    private func recordExisting(_ url: URL, for media: MediaRecord) async {
        try? await ingest?.setMediaState(chatJid: media.chatJid, messageId: media.messageId, state: .downloaded, localPath: url.path)
    }

    // MARK: Download

    public func download(_ media: MediaRecord) async throws -> URL {
        if let url = localURL(for: media) {
            if media.downloadState != .downloaded { await recordExisting(url, for: media) }
            return url
        }
        let key = Self.key(for: media)
        if let task = inFlight[key] { return try await task.value }

        let dest = fileURL(for: media)
        let bridge = self.bridge
        let ingest = self.ingest
        let center = progress
        let task = Task<URL, any Error> {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let part = dest.appendingPathExtension("part")
            try? await ingest?.setMediaState(chatJid: media.chatJid, messageId: media.messageId, state: .downloading, localPath: nil)
            do {
                try await bridge.downloadMedia(media: media.bridgeMedia, destPath: part.path, progress: ProgressRelay(key: key, center: center))
                if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: part) }
                else { try FileManager.default.moveItem(at: part, to: dest) }
                center.post(key, nil)
                try? await ingest?.setMediaState(chatJid: media.chatJid, messageId: media.messageId, state: .downloaded, localPath: dest.path)
                return dest
            } catch {
                try? FileManager.default.removeItem(at: part)
                center.post(key, nil)
                try? await ingest?.setMediaState(chatJid: media.chatJid, messageId: media.messageId, state: .failed, localPath: nil)
                throw error
            }
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// A file AVFoundation can play. Voice notes (Ogg/Opus) are remuxed once to a `.caf` next to the original.
    public func playableAudioURL(_ media: MediaRecord) async throws -> URL {
        let src = try await download(media)
        guard src.pathExtension == "ogg" || (media.mimetype ?? "").hasPrefix("audio/ogg") else { return src }
        let caf = src.deletingPathExtension().appendingPathExtension("caf")
        if FileManager.default.fileExists(atPath: caf.path) { return caf }
        let remux = self.remux
        try await Task.detached(priority: .userInitiated) {
            let tmp = caf.appendingPathExtension("part")
            try remux(src.path, tmp.path)
            try? FileManager.default.removeItem(at: caf)
            try FileManager.default.moveItem(at: tmp, to: caf)
        }.value
        return caf
    }

    /// Copies a file we just sent into the content-addressed store so it is not re-downloaded.
    /// Returns the stored file, or nil if the copy failed.
    @discardableResult
    public func adoptSentFile(_ source: URL, for media: MediaRecord) -> URL? {
        guard !media.fileSha256.isEmpty else { return nil }
        let dest = fileURL(for: media)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: source, to: dest) } catch { return nil }
        return dest
    }

    /// Upload progress for an optimistic row, keyed like `key(for:)` keys pending media.
    nonisolated func uploadRelay(chatJid: String, localId: String) -> ProgressRelay {
        ProgressRelay(key: "\(chatJid)/\(localId)", center: progress)
    }

    nonisolated func clearUploadProgress(chatJid: String, localId: String) {
        progress.post("\(chatJid)/\(localId)", nil)
    }
}

/// Bridges Rust progress callbacks to the main-actor progress center, throttled to 1% steps.
final class ProgressRelay: ProgressSink, Sendable {
    let key: String
    let center: MediaProgressCenter
    private let last = Mutex<Int>(-1)

    init(key: String, center: MediaProgressCenter) {
        self.key = key
        self.center = center
    }

    func onProgress(done: UInt64, total: UInt64) {
        let pct = total > 0 ? Int(min(100, done * 100 / total)) : 0
        // A retry truncates back to 0, so any change (including backwards) is reported.
        let changed = last.withLock { old in
            guard old != pct else { return false }
            old = pct
            return true
        }
        guard changed else { return }
        center.post(key, Double(pct) / 100)
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
