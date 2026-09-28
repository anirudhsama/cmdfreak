import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import WAKit

@MainActor
protocol MessageCellDelegate: AnyObject {
    var mediaStore: MediaStore { get }
    func cell(_ cell: MessageCell, didClickQuote targetId: String)
    func cell(_ cell: MessageCell, didToggleReaction emoji: String, on item: MessageItem)
    func cell(_ cell: MessageCell, didClickMedia item: MessageItem)
    func cell(_ cell: MessageCell, didClickRetry item: MessageItem)
    func cell(_ cell: MessageCell, menuFor item: MessageItem) -> NSMenu?
    func cell(_ cell: MessageCell, beginDragOf fileURL: URL, with event: NSEvent)
}

/// One message row. Everything is positioned from the `LayoutPlan`; nothing is measured here.
final class MessageCell: NSTableCellView {
    typealias M = MessageTextConfiguration.Metrics
    typealias C = MessageTextConfiguration

    weak var delegate: (any MessageCellDelegate)?
    private(set) var item: MessageItem?
    private(set) var plan: LayoutPlan?
    var isRowSelected = false { didSet { if oldValue != isRowSelected { needsDisplay = true } } }

    private var textView: MessageTextView?
    private var mediaLayer: CALayer?
    private var blurFilter: CIFilter? = {
        let f = CIFilter(name: "CIGaussianBlur")
        f?.setValue(6, forKey: kCIInputRadiusKey)
        return f
    }()
    private var queuePlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var thumbTask: Task<Void, Never>?
    private var fullTask: Task<Void, Never>?
    private var animatedStop = false
    private var animating = false
    /// GIF loop / animated sticker waiting to start once the row is on screen.
    private var pendingMotion: (url: URL, isGif: Bool)?
    /// Bumped on reuse so a scheduled motion start for the previous message is dropped.
    private var motionToken = 0
    private var downloadFraction: Double?
    private var audioState: AudioPlaybackController.State?
    private var showsFullImage = false
    /// Media chrome (play button, duration, progress) must sit above the media sublayer, which is
    /// below the cell's own drawing; this subview draws it.
    private let overlay = OverlayView()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        overlay.cell = self
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Configure

    func configure(item: MessageItem, plan: LayoutPlan) {
        let changedMessage = self.item?.id != item.id
        self.item = item
        self.plan = plan
        if changedMessage { resetTransient() }

        // Body text
        if let text = plan.text, plan.shape != .system {
            let tv = textView ?? {
                let v = MessageTextView.make()
                addSubview(v)
                textView = v
                return v
            }()
            tv.setContent(text.text, size: text.frame.size)
            tv.isHidden = false
        } else {
            textView?.isHidden = true
        }

        configureMedia(plan: plan)
        configureAudio()
        needsLayout = true
        needsDisplay = true
        overlay.needsDisplay = true
    }

    private func resetTransient() {
        thumbTask?.cancel()
        fullTask?.cancel()
        thumbTask = nil
        fullTask = nil
        stopAnimation()
        stopPlayer()
        pendingMotion = nil
        motionToken &+= 1
        showsFullImage = false
        downloadFraction = nil
        mediaLayer?.contents = nil
        mediaLayer?.filters = nil
        audioState = nil
        AudioPlaybackController.shared.unobserve(self)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetTransient()
        item = nil
        plan = nil
        textView?.isHidden = true
        mediaLayer?.isHidden = true
    }

    // MARK: Media

    private func configureMedia(plan: LayoutPlan) {
        var frame: CGRect?
        var thumbKey: String?
        var fileKey: String?
        var pixels = 0
        var isGif = false
        var isSticker = false
        var animatedSticker = false
        switch plan.content {
        case .media(let m):
            frame = m.frame; thumbKey = m.thumbKey; fileKey = m.fileKey; pixels = m.pixelSize; isGif = m.kind == .gif
        case .sticker(let f, let fk, let tk, let animated):
            frame = f; thumbKey = tk; fileKey = fk; pixels = Int(M.stickerSize * 2); isSticker = true; animatedSticker = animated
        default:
            break
        }
        guard let frame, let item else {
            mediaLayer?.isHidden = true
            return
        }
        let layer = mediaLayer ?? {
            let l = CALayer()
            l.contentsGravity = .resizeAspectFill
            l.masksToBounds = true
            l.magnificationFilter = .linear
            l.minificationFilter = .trilinear
            self.layer?.insertSublayer(l, at: 0)
            mediaLayer = l
            return l
        }()
        layer.isHidden = false
        layer.frame = frame
        layer.cornerRadius = isSticker ? 0 : M.mediaRadius - 1
        layer.contentsGravity = isSticker ? .resizeAspect : .resizeAspectFill
        layer.backgroundColor = isSticker ? nil : C.quoteBackground.cgColor
        layer.contentsScale = window?.backingScaleFactor ?? 2

        let media = item.media
        let localURL = media?.downloadState == .downloaded ? media?.localPath.map { URL(filePath: $0) } : nil
        let cache = ThumbnailCache.shared

        // Full-resolution file (present locally) wins; the tiny thumbnail is the blurred placeholder.
        if let localURL, let fileKey {
            if let img = cache.cached(key: fileKey, maxPixelSize: pixels) {
                showFull(img)
            } else {
                showThumb(cache: cache, key: thumbKey, data: media?.jpegThumbnail)
                let id = item.id
                fullTask = Task { [weak self] in
                    let img = await cache.image(key: fileKey, source: .file(localURL), maxPixelSize: pixels)
                    guard let self, self.item?.id == id, let img else { return }
                    self.showFull(img)
                }
            }
            // Player / animation setup is deferred until the row is displayed, not done in `viewFor`.
            if isGif, playerLayer == nil { scheduleMotion(url: localURL, isGif: true) }
            if animatedSticker, !animating { scheduleMotion(url: localURL, isGif: false) }
        } else {
            showThumb(cache: cache, key: thumbKey, data: media?.jpegThumbnail)
        }
    }

    private func showThumb(cache: ThumbnailCache, key: String?, data: Data?) {
        guard let key, let data, !data.isEmpty, let item else { return }
        if let img = cache.cached(key: key, maxPixelSize: 320) {
            if !showsFullImage { setPlaceholder(img) }
            return
        }
        let id = item.id
        thumbTask = Task { [weak self] in
            let img = await cache.image(key: key, source: .data(data), maxPixelSize: 320)
            guard let self, self.item?.id == id, !self.showsFullImage, let img else { return }
            self.setPlaceholder(img)
        }
    }

    private func setPlaceholder(_ img: CGImage) {
        mediaLayer?.contents = img
        // Upscaled tiny JPEG plus a light blur reads as "loading" without a spinner.
        if case .media = plan?.content { mediaLayer?.filters = blurFilter.map { [$0] } }
    }

    private func showFull(_ img: CGImage) {
        showsFullImage = true
        mediaLayer?.filters = nil
        mediaLayer?.contents = img
        needsDisplay = true
        overlay.needsDisplay = true
    }

    private func scheduleMotion(url: URL, isGif: Bool) {
        pendingMotion = (url, isGif)
        guard window != nil else { return }  // `viewDidMoveToWindow` picks it up
        let token = motionToken
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.startPendingMotion(token: token) }
        }
    }

    private func startPendingMotion(token: Int) {
        guard token == motionToken, window != nil, let motion = pendingMotion else { return }
        pendingMotion = nil
        if motion.isGif {
            if case .media(let m) = plan?.content { startPlayer(url: motion.url, in: m.frame) }
        } else {
            startAnimation(url: motion.url)
        }
    }

    /// A few idle muted players shared by GIF rows; creating one per configure is wasteful.
    private static var playerPool: [AVQueuePlayer] = []

    private static func dequeuePlayer() -> AVQueuePlayer {
        if let p = playerPool.popLast() { return p }
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        return player
    }

    private static func recycle(_ player: AVQueuePlayer) {
        player.pause()
        player.removeAllItems()
        if playerPool.count < 4 { playerPool.append(player) }
    }

    private func startPlayer(url: URL, in frame: CGRect) {
        guard playerLayer == nil else { return }
        let player = Self.dequeuePlayer()
        let pl = AVPlayerLayer(player: player)
        pl.videoGravity = .resizeAspectFill
        pl.frame = frame
        pl.cornerRadius = M.mediaRadius - 1
        pl.masksToBounds = true
        layer?.insertSublayer(pl, above: mediaLayer)
        playerLayer = pl
        queuePlayer = player
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        if window != nil { player.play() }
    }

    private func stopPlayer() {
        looper?.disableLooping()
        looper = nil
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        if let queuePlayer { Self.recycle(queuePlayer) }
        queuePlayer = nil
    }

    private func startAnimation(url: URL) {
        guard !animating else { return }
        animating = true
        animatedStop = false
        let id = item?.id
        let status = CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak self] _, image, stop in
            MainActor.assumeIsolated {
                guard let self, self.item?.id == id, !self.animatedStop, self.window != nil else {
                    stop.pointee = true
                    self?.animating = false
                    return
                }
                self.mediaLayer?.contents = image
            }
        }
        if status != noErr { animating = false }
    }

    private func stopAnimation() {
        animatedStop = true
        animating = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        mediaLayer?.contentsScale = window?.backingScaleFactor ?? 2
        if window == nil {
            queuePlayer?.pause()
        } else {
            queuePlayer?.play()
            if let motion = pendingMotion {
                scheduleMotion(url: motion.url, isGif: motion.isGif)
            } else if case .sticker(_, _, _, true) = plan?.content, !animating, let p = item?.media?.localPath, item?.media?.downloadState == .downloaded {
                scheduleMotion(url: URL(filePath: p), isGif: false)
            }
        }
    }

    // MARK: Audio

    private func configureAudio() {
        guard case .audio = plan?.content, let item else { return }
        let controller = AudioPlaybackController.shared
        audioState = controller.isCurrent(item.id) ? controller.state : nil
        controller.observe(self) { [weak self] state in
            guard let self, let item = self.item else { return }
            let mine = state?.messageId == item.id ? state : nil
            if mine != self.audioState {
                self.audioState = mine
                if case .audio(let a) = self.plan?.content { self.setNeedsDisplay(a.frame.insetBy(dx: -4, dy: -4)) }
            }
        }
    }

    func setDownloadFraction(_ f: Double?) {
        guard f != downloadFraction else { return }
        downloadFraction = f
        needsDisplay = true
        overlay.needsDisplay = true
    }

    fileprivate func drawOverlays() {
        guard let plan, let item, case .media(let m) = plan.content else { return }
        drawMediaOverlay(m, item: item)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        overlay.frame = bounds
        guard let plan else { return }
        if let text = plan.text, let textView, !textView.isHidden {
            textView.frame = text.frame
        }
        switch plan.content {
        case .media(let m):
            mediaLayer?.frame = m.frame
            playerLayer?.frame = m.frame
        case .sticker(let f, _, _, _):
            mediaLayer?.frame = f
        default:
            break
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let plan, let item else { return }
        if isRowSelected {
            Palette.green.withAlphaComponent(0.10).setFill()
            bounds.fill()
        }
        switch plan.shape {
        case .system:
            let path = NSBezierPath(roundedRect: plan.bubble, xRadius: plan.bubble.height / 2, yRadius: plan.bubble.height / 2)
            C.systemPill.setFill()
            path.fill()
            plan.text?.text.draw(in: plan.text!.frame)
            return
        case .bubble:
            drawBubble(plan)
        case .bare:
            break
        }
        if let s = plan.sender { s.text.draw(in: s.frame) }
        if let f = plan.forwarded { f.text.draw(in: f.frame) }
        if let q = plan.quote { drawQuote(q) }
        drawContent(plan, item: item)
        if let meta = plan.meta { drawMeta(meta, plan: plan) }
        for chip in plan.reactions { drawChip(chip) }
        if plan.isFailed { drawFailedBadge(plan) }
    }

    private func drawBubble(_ plan: LayoutPlan) {
        let r = plan.bubble
        (plan.outgoing ? C.outgoingBubble : C.incomingBubble).setFill()
        NSBezierPath(roundedRect: r, xRadius: M.bubbleRadius, yRadius: M.bubbleRadius).fill()
        guard plan.hasTail else { return }
        // iMessage tail on the last message of a run: the bottom edge sweeps out past the corner
        // into a point and curls back up into the side. Filled separately (the colors are opaque).
        let dir: CGFloat = plan.outgoing ? 1 : -1
        let edge = plan.outgoing ? r.maxX : r.minX
        let b = r.maxY
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: edge - dir * 14, y: b - 12))
        tail.line(to: NSPoint(x: edge, y: b - 16))
        tail.curve(to: NSPoint(x: edge + dir * 6, y: b),
                   controlPoint1: NSPoint(x: edge, y: b - 6), controlPoint2: NSPoint(x: edge + dir * 2, y: b - 1))
        tail.curve(to: NSPoint(x: edge - dir * 10, y: b - 3),
                   controlPoint1: NSPoint(x: edge + dir * 1, y: b + 0.5), controlPoint2: NSPoint(x: edge - dir * 5, y: b))
        tail.close()
        tail.fill()
    }

    /// Quote, document, card and poll wells.
    private var well: NSColor { C.quoteBackground }

    private func drawQuote(_ q: LayoutPlan.Quote) {
        let path = NSBezierPath(roundedRect: q.frame, xRadius: M.quoteRadius, yRadius: M.quoteRadius)
        well.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        q.color.setFill()
        NSRect(x: q.frame.minX, y: q.frame.minY, width: M.quoteBar, height: q.frame.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let textX = q.frame.minX + M.quoteBar + 8
        let w = q.frame.width - M.quoteBar - 14
        q.name.draw(with: NSRect(x: textX, y: q.frame.minY + 6, width: w, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        q.snippet.draw(with: NSRect(x: textX, y: q.frame.minY + 22, width: w, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawContent(_ plan: LayoutPlan, item: MessageItem) {
        switch plan.content {
        case .none, .sticker:
            break
        case .media:
            break  // drawn by `overlay`, above the media layer
        case .document(let d):
            drawDocument(d, item: item)
        case .audio(let a):
            drawAudio(a, item: item)
        case .card(let c):
            drawCard(c)
        case .poll(let p):
            drawPoll(p)
        }
    }

    /// Download or upload progress. A pending outgoing media row shows an empty ring until the
    /// first upload tick arrives.
    private func transferFraction(_ item: MessageItem) -> Double? {
        if let downloadFraction { return downloadFraction }
        if item.media?.downloadState == .downloading { return 0 }
        if item.message.fromMe, item.message.status == .pending, item.media != nil { return 0 }
        return nil
    }

    private func drawMediaOverlay(_ m: LayoutPlan.Media, item: MessageItem) {
        let f = m.frame
        let downloaded = item.media?.downloadState == .downloaded && item.media?.localPath != nil
        if let fraction = transferFraction(item) {
            drawProgressRing(center: NSPoint(x: f.midX, y: f.midY), fraction: fraction)
            return
        }
        if item.message.fromMe, item.message.status == .failed {
            drawGlyphCircle(center: NSPoint(x: f.midX, y: f.midY), symbol: "arrow.up", diameter: 44)
            return
        }
        switch m.kind {
        case .video:
            if downloaded {
                drawGlyphCircle(center: NSPoint(x: f.midX, y: f.midY), symbol: "play.fill", diameter: 44)
            } else {
                drawGlyphCircle(center: NSPoint(x: f.midX, y: f.midY), symbol: "arrow.down", diameter: 44)
                if let size = item.media?.fileLength, size > 0 {
                    drawPill(Int64(size).formatted(ByteCountFormatStyle(style: .file)), at: NSPoint(x: f.midX, y: f.midY + 32), centered: true)
                }
            }
            if let d = m.durationText { drawPill(d, at: NSPoint(x: f.minX + 8, y: f.minY + 8), centered: false) }
        case .gif:
            if !downloaded { drawGlyphCircle(center: NSPoint(x: f.midX, y: f.midY), symbol: "arrow.down", diameter: 40) }
            drawPill("GIF", at: NSPoint(x: f.minX + 8, y: f.minY + 8), centered: false)
        case .image:
            if !downloaded, item.media?.downloadState == .failed {
                drawGlyphCircle(center: NSPoint(x: f.midX, y: f.midY), symbol: "arrow.clockwise", diameter: 40)
            }
        }
    }

    private func drawDocument(_ d: LayoutPlan.Document, item: MessageItem) {
        let f = d.frame
        NSBezierPath(roundedRect: f, xRadius: 8, yRadius: 8).fill(with: well)
        let icon = Self.icon(forFileName: d.fileName, mimetype: item.media?.mimetype)
        icon.draw(in: NSRect(x: f.minX + 8, y: f.minY + 10, width: 36, height: 36), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let downloaded = item.media?.downloadState == .downloaded && item.media?.localPath != nil
        let transfer = transferFraction(item)
        let trailing: CGFloat = downloaded && transfer == nil ? 12 : 40
        d.name.draw(with: NSRect(x: f.minX + 52, y: f.minY + 11, width: f.width - 52 - trailing, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        d.detail.draw(with: NSRect(x: f.minX + 52, y: f.minY + 31, width: f.width - 52 - trailing, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let fraction = transfer {
            drawProgressRing(center: NSPoint(x: f.maxX - 22, y: f.midY), fraction: fraction, diameter: 24)
        } else if !downloaded {
            drawGlyphCircle(center: NSPoint(x: f.maxX - 22, y: f.midY), symbol: "arrow.down", diameter: 26, tinted: true)
        }
    }

    private func drawAudio(_ a: LayoutPlan.Audio, item: MessageItem) {
        let f = a.frame
        let state = audioState
        let downloaded = item.media?.downloadState == .downloaded
        let btn = NSRect(x: f.minX, y: f.midY - 17, width: 34, height: 34)
        if state?.isLoading == true || (downloadFraction != nil) {
            drawProgressRing(center: NSPoint(x: btn.midX, y: btn.midY), fraction: downloadFraction ?? 0, diameter: 30)
        } else {
            let symbol = state?.isPlaying == true ? "pause.fill" : (downloaded || item.media != nil ? "play.fill" : "arrow.down")
            drawGlyphCircle(center: NSPoint(x: btn.midX, y: btn.midY), symbol: symbol, diameter: 34, tinted: true)
        }
        // Waveform
        let waveX = btn.maxX + 10
        let rateW: CGFloat = state != nil ? 34 : 0
        let waveW = f.width - (waveX - f.minX) - rateW - 4
        let bars = a.waveform
        let count = bars.count
        let step = waveW / CGFloat(max(1, count))
        let barW = max(2, step * 0.6)
        let midY = f.minY + 18
        let progress = state?.progress ?? 0
        for (i, v) in bars.enumerated() {
            let h = max(3, CGFloat(v) * 24)
            let x = waveX + CGFloat(i) * step
            let played = Double(i) / Double(max(1, count)) < progress
            (played ? Palette.green : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: midY - h / 2, width: barW, height: h), xRadius: 1, yRadius: 1).fill()
        }
        let elapsedText: String
        if let state, state.elapsed > 0 || state.isPlaying {
            elapsedText = LayoutPlanner.durationText(Int(state.elapsed)) + " / " + a.durationText
        } else {
            elapsedText = a.durationText
        }
        let ta: [NSAttributedString.Key: Any] = [.font: C.cardSecondary, .foregroundColor: NSColor.secondaryLabelColor]
        NSAttributedString(string: elapsedText, attributes: ta).draw(at: NSPoint(x: waveX, y: f.minY + 32))
        if a.isVoice {
            let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
            mic?.draw(in: NSRect(x: waveX + waveW - 12, y: f.minY + 34, width: 10, height: 10), from: .zero, operation: .sourceOver, fraction: 0.6, respectFlipped: true, hints: nil)
        }
        if let state {
            let rect = NSRect(x: f.maxX - rateW + 2, y: f.midY - 11, width: rateW - 4, height: 22)
            NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill(with: well)
            let label = NSAttributedString(string: Self.rateLabel(state.rate), attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.labelColor])
            let w = label.size().width
            label.draw(at: NSPoint(x: rect.midX - w / 2, y: rect.minY + 4))
        }
    }

    static func rateLabel(_ r: Float) -> String {
        r == 1 ? "1×" : (r == 1.5 ? "1.5×" : "2×")
    }

    private func drawCard(_ c: LayoutPlan.Card) {
        let f = c.frame
        NSBezierPath(roundedRect: f, xRadius: 8, yRadius: 8).fill(with: well)
        drawGlyphCircle(center: NSPoint(x: f.minX + 26, y: f.midY), symbol: c.symbol, diameter: 34, tinted: true)
        c.title.draw(with: NSRect(x: f.minX + 52, y: f.minY + 11, width: f.width - 62, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        c.subtitle.draw(with: NSRect(x: f.minX + 52, y: f.minY + 31, width: f.width - 62, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawPoll(_ p: LayoutPlan.Poll) {
        p.question.text.draw(in: p.question.frame)
        for o in p.options {
            let bar = o.frame
            NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill(with: well)
            if o.fraction > 0 {
                let fill = NSRect(x: bar.minX, y: bar.minY, width: bar.width * o.fraction, height: bar.height)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).addClip()
                Palette.green.withAlphaComponent(o.mine ? 0.35 : 0.18).setFill()
                fill.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            o.label.draw(with: NSRect(x: bar.minX + 8, y: bar.minY + 4, width: bar.width - 44, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let cw = o.count.size().width
            o.count.draw(at: NSPoint(x: bar.maxX - 8 - cw, y: bar.minY + 5))
        }
        p.footer.text.draw(in: p.footer.frame)
    }

    private func drawMeta(_ meta: LayoutPlan.Meta, plan: LayoutPlan) {
        var textAttrs = C.metaAttributes
        var tickColor = NSColor.secondaryLabelColor
        if meta.overlay {
            let pill = meta.frame.insetBy(dx: -6, dy: -2)
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill(with: NSColor.black.withAlphaComponent(0.45))
            textAttrs[.foregroundColor] = NSColor.white
            tickColor = .white
        } else if plan.shape == .bare {
            let pill = meta.frame.insetBy(dx: -5, dy: -1)
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill(with: C.systemPill)
        }
        NSAttributedString(string: meta.text, attributes: textAttrs).draw(at: NSPoint(x: meta.frame.minX, y: meta.frame.minY))
        if let status = meta.status {
            let tick = NSRect(x: meta.frame.maxX - M.tickWidth, y: meta.frame.minY + 1, width: M.tickWidth, height: 11)
            ReceiptDrawing.draw(status, in: tick, color: tickColor)
        }
    }

    /// Filled with the bubble's own color, cut out of the bubble by a ring of the chat background.
    private func drawChip(_ chip: LayoutPlan.Chip) {
        let ring = chip.frame.insetBy(dx: -2, dy: -2)
        NSBezierPath(roundedRect: ring, xRadius: ring.height / 2, yRadius: ring.height / 2).fill(with: .windowBackgroundColor)
        NSBezierPath(roundedRect: chip.frame, xRadius: chip.frame.height / 2, yRadius: chip.frame.height / 2)
            .fill(with: plan?.outgoing == true ? C.outgoingBubble : C.incomingBubble)
        var x = chip.frame.minX + 7
        let emoji = NSAttributedString(string: chip.emoji, attributes: [.font: C.reaction])
        emoji.draw(at: NSPoint(x: x, y: chip.frame.minY + 2))
        x += emoji.size().width + 4
        if chip.count > 1 {
            NSAttributedString(string: "\(chip.count)", attributes: [.font: C.cardSecondary, .foregroundColor: NSColor.secondaryLabelColor])
                .draw(at: NSPoint(x: x, y: chip.frame.minY + 4))
        }
    }

    private func drawFailedBadge(_ plan: LayoutPlan) {
        let r = failedBadgeRect(plan)
        let img = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Failed")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        NSColor.systemRed.set()
        img?.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let label = NSAttributedString(string: "Not sent · Retry", attributes: [.font: C.cardSecondary, .foregroundColor: NSColor.systemRed])
        label.draw(at: NSPoint(x: r.minX - label.size().width - 4, y: r.minY + 1))
    }

    private func failedBadgeRect(_ plan: LayoutPlan) -> NSRect {
        NSRect(x: plan.bubble.minX - 22, y: plan.bubble.maxY - 20, width: 16, height: 16)
    }

    // MARK: Drawing helpers

    private func drawGlyphCircle(center: NSPoint, symbol: String, diameter: CGFloat, tinted: Bool = false) {
        let rect = NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        NSBezierPath(ovalIn: rect).fill(with: tinted ? Palette.green : NSColor.black.withAlphaComponent(0.5))
        let cfg = NSImage.SymbolConfiguration(pointSize: diameter * 0.4, weight: .semibold)
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let tinted = img.tinted(.white)
        let s = tinted.size
        let offset: CGFloat = symbol == "play.fill" ? diameter * 0.04 : 0
        tinted.draw(in: NSRect(x: center.x - s.width / 2 + offset, y: center.y - s.height / 2, width: s.width, height: s.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawProgressRing(center: NSPoint, fraction: Double, diameter: CGFloat = 44) {
        let rect = NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        NSBezierPath(ovalIn: rect).fill(with: NSColor.black.withAlphaComponent(0.45))
        let ring = NSBezierPath()
        let r = diameter / 2 - 5
        ring.appendArc(withCenter: center, radius: r, startAngle: 90, endAngle: 90 - 360 * max(0.02, fraction), clockwise: true)
        ring.lineWidth = 2.5
        ring.lineCapStyle = .round
        NSColor.white.setStroke()
        ring.stroke()
    }

    private func drawPill(_ text: String, at origin: NSPoint, centered: Bool) {
        let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white])
        let size = attr.size()
        let rect = NSRect(x: centered ? origin.x - size.width / 2 - 6 : origin.x, y: origin.y, width: size.width + 12, height: size.height + 3)
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill(with: NSColor.black.withAlphaComponent(0.5))
        attr.draw(at: NSPoint(x: rect.minX + 6, y: rect.minY + 1.5))
    }

    private static let iconCache = NSCache<NSString, NSImage>()

    static func icon(forFileName name: String, mimetype: String?) -> NSImage {
        let key = "\(name)|\(mimetype ?? "")" as NSString
        if let hit = iconCache.object(forKey: key) { return hit }
        let ext = name.contains(".") ? String(name.split(separator: ".").last ?? "") : ""
        let type = UTType(filenameExtension: ext) ?? mimetype.flatMap { UTType(mimeType: $0) } ?? .data
        let img = NSWorkspace.shared.icon(for: type)
        iconCache.setObject(img, forKey: key)
        return img
    }

    // MARK: - Interaction

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return nil }
        return delegate?.cell(self, menuFor: item)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let plan, let item, let delegate else { return super.mouseDown(with: event) }
        if let q = plan.quote, q.frame.contains(p) {
            delegate.cell(self, didClickQuote: q.targetId)
            return
        }
        for chip in plan.reactions where chip.frame.contains(p) {
            delegate.cell(self, didToggleReaction: chip.emoji, on: item)
            return
        }
        if plan.isFailed, failedBadgeRect(plan).insetBy(dx: -90, dy: -4).contains(p) {
            delegate.cell(self, didClickRetry: item)
            return
        }
        switch plan.content {
        case .media(let m) where m.frame.contains(p):
            delegate.cell(self, didClickMedia: item)
            return
        case .sticker(let f, _, _, _) where f.contains(p):
            delegate.cell(self, didClickMedia: item)
            return
        case .document(let d) where d.frame.contains(p):
            // Drag-out starts on drag; a click opens.
            if let path = item.media?.localPath, item.media?.downloadState == .downloaded {
                let url = URL(filePath: path)
                if let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: Date(timeIntervalSinceNow: 0.3), inMode: .eventTracking, dequeue: true),
                   next.type == .leftMouseDragged {
                    delegate.cell(self, beginDragOf: url, with: next)
                    return
                }
            }
            delegate.cell(self, didClickMedia: item)
            return
        case .audio(let a) where a.frame.contains(p):
            let controller = AudioPlaybackController.shared
            let btn = NSRect(x: a.frame.minX, y: a.frame.midY - 17, width: 34, height: 34)
            if btn.contains(p) {
                controller.toggle(item, media: delegate.mediaStore)
            } else if controller.isCurrent(item.id), p.x > a.frame.maxX - 36 {
                controller.cycleRate()
            } else if controller.isCurrent(item.id) {
                let waveX = a.frame.minX + 44
                let waveW = a.frame.width - 44 - 38
                controller.seek(Double(max(0, min(1, (p.x - waveX) / waveW))))
            } else {
                controller.toggle(item, media: delegate.mediaStore)
            }
            return
        case .card(let c) where c.frame.contains(p):
            if c.kind == .location, let loc = item.message.extra?.location,
               let url = URL(string: "https://maps.apple.com/?ll=\(loc.latitude),\(loc.longitude)&q=\(loc.name?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Location")") {
                NSWorkspace.shared.open(url)
            }
            return
        default:
            break
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        guard let plan else { return }
        if let q = plan.quote { addCursorRect(q.frame, cursor: .pointingHand) }
        for chip in plan.reactions { addCursorRect(chip.frame, cursor: .pointingHand) }
        switch plan.content {
        case .media(let m): addCursorRect(m.frame, cursor: .pointingHand)
        case .document(let d): addCursorRect(d.frame, cursor: .pointingHand)
        case .audio(let a): addCursorRect(NSRect(x: a.frame.minX, y: a.frame.midY - 17, width: 34, height: 34), cursor: .pointingHand)
        default: break
        }
    }
}

/// Clock / one tick / two ticks / blue ticks, drawn as paths (SF Symbols has no double checkmark).
enum ReceiptDrawing {
    static func draw(_ status: MessageStatus, in rect: NSRect, color: NSColor) {
        switch status {
        case .pending:
            let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            let img = NSImage(systemSymbolName: "clock", accessibilityDescription: "Pending")?.withSymbolConfiguration(cfg)?.tinted(color)
            img?.draw(in: NSRect(x: rect.maxX - 10, y: rect.minY, width: 10, height: 10), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .failed:
            let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            let img = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "Failed")?.withSymbolConfiguration(cfg)?.tinted(.systemRed)
            img?.draw(in: NSRect(x: rect.maxX - 10, y: rect.minY, width: 10, height: 10), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .sent:
            tick(at: rect.maxX - 9, y: rect.minY, color: color)
        case .delivered:
            tick(at: rect.maxX - 13, y: rect.minY, color: color)
            tick(at: rect.maxX - 9, y: rect.minY, color: color)
        case .read, .played:
            tick(at: rect.maxX - 13, y: rect.minY, color: MessageTextConfiguration.readTick)
            tick(at: rect.maxX - 9, y: rect.minY, color: MessageTextConfiguration.readTick)
        }
    }

    private static func tick(at x: CGFloat, y: CGFloat, color: NSColor) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x, y: y + 5.5))
        p.line(to: NSPoint(x: x + 3, y: y + 8.5))
        p.line(to: NSPoint(x: x + 9, y: y + 2.5))
        p.lineWidth = 1.4
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        color.setStroke()
        p.stroke()
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            color.set()
            rect.fill()
            self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        img.isTemplate = false
        return img
    }
}

extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}

private final class OverlayView: NSView {
    weak var cell: MessageCell?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { cell?.drawOverlays() }
}
