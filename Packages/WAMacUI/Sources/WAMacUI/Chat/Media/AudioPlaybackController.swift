import AVFoundation
import AppKit
import WAKit

/// One audio message plays at a time; playback outlives chat switches. Cells subscribe by id.
@MainActor
final class AudioPlaybackController: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlaybackController()

    struct State: Equatable {
        var messageId: String
        var chatJid: String
        var isPlaying: Bool
        var progress: Double  // 0…1
        var elapsed: TimeInterval
        var duration: TimeInterval
        var rate: Float
        var isLoading: Bool
    }

    private(set) var state: State?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    private var observers: [ObjectIdentifier: (State?) -> Void] = [:]

    static let rates: [Float] = [1, 1.5, 2]

    func observe(_ owner: AnyObject, _ block: @escaping (State?) -> Void) {
        observers[ObjectIdentifier(owner)] = block
    }

    func unobserve(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
    }

    func isCurrent(_ messageId: String) -> Bool { state?.messageId == messageId }

    /// Toggles play/pause for `item`, downloading and remuxing first if needed.
    func toggle(_ item: MessageItem, media: MediaStore) {
        if let s = state, s.messageId == item.id {
            if s.isLoading { return }
            if s.isPlaying { pause() } else { resume() }
            return
        }
        stop()
        guard let record = item.media else { return }
        state = State(messageId: item.id, chatJid: item.message.chatJid, isPlaying: false, progress: 0, elapsed: 0,
                      duration: TimeInterval(record.durationSecs ?? 0), rate: state?.rate ?? 1, isLoading: true)
        notify()
        let id = item.id
        loadTask = Task { [weak self] in
            do {
                let url = try await media.playableAudioURL(record)
                guard let self, self.state?.messageId == id else { return }
                let p = try AVAudioPlayer(contentsOf: url)
                p.enableRate = true
                p.rate = self.state?.rate ?? 1
                p.delegate = self
                p.prepareToPlay()
                self.player = p
                self.state?.isLoading = false
                self.state?.duration = p.duration
                self.resume()
            } catch {
                Signposts.log.error("audio load failed: \(error)")
                guard let self, self.state?.messageId == id else { return }
                self.state = nil
                self.notify()
            }
        }
    }

    func cycleRate() {
        guard var s = state else { return }
        let i = Self.rates.firstIndex(of: s.rate) ?? 0
        s.rate = Self.rates[(i + 1) % Self.rates.count]
        player?.rate = s.rate
        state = s
        notify()
    }

    func seek(_ fraction: Double) {
        guard let player, var s = state else { return }
        player.currentTime = max(0, min(player.duration, player.duration * fraction))
        s.elapsed = player.currentTime
        s.progress = fraction
        state = s
        notify()
    }

    private func resume() {
        guard let player else { return }
        player.play()
        state?.isPlaying = true
        startTimer()
        notify()
    }

    private func pause() {
        player?.pause()
        state?.isPlaying = false
        stopTimer()
        notify()
    }

    func stop() {
        loadTask?.cancel()
        player?.stop()
        player = nil
        stopTimer()
        state = nil
        notify()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player, var s = state else { return }
        s.elapsed = player.currentTime
        s.progress = player.duration > 0 ? player.currentTime / player.duration : 0
        state = s
        notify()
    }

    private func notify() {
        for o in observers.values { o(state) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard var s = self.state else { return }
            s.isPlaying = false
            s.progress = 0
            s.elapsed = 0
            self.state = s
            self.stopTimer()
            self.player?.currentTime = 0
            self.notify()
        }
    }
}
