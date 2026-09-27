import CoreImage
import Foundation
import WACoreFFI
import WAKit

// wa-cli — M1 smoke tests for the Rust bridge.
//
//   wa-cli events [--seconds N] [--nudge-after N]
//                                      connect, stream events as JSON lines; prints QR codes when unpaired
//   wa-cli qr TEXT                     render a payload as a terminal QR (checks the pairing render path)
//   wa-cli send-self "text"            send a text to your own number ("Message yourself")
//   wa-cli send-media-self FILE... [--kind image|video|gif|document] [--caption TEXT]
//                                      send files to your own number, re-download, verify round trip
//   wa-cli download [--out DIR]        newest image + voice note from the capture → download → remux .caf
//   wa-cli import-capture [DIR]        replay a wa-link capture and print summary counts
//   wa-cli ingest-capture [--db PATH] replay the capture through WAKit's IngestActor into an app DB
//                                      (default: the app's real app.sqlite)
//   wa-cli remux SRC.ogg DST.caf
//
// Env: WA_DATA_DIR (default ~/Library/Application Support/BetterWA), WA_LOG=debug|info|warn.
// Stats (incl. events_dropped) are printed to stderr on exit.

let home = FileManager.default.homeDirectoryForCurrentUser.path
let dataDir = ProcessInfo.processInfo.environment["WA_DATA_DIR"] ?? "\(home)/Library/Application Support/BetterWA"
let captureDir = "\(dataDir)/capture"

func err(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

final class StderrLog: LogSink, @unchecked Sendable {
    func onLog(level: LogLevel, target: String, message: String) {
        err("[\(level)] \(target): \(message)")
    }
}

/// Collects state from the event stream; `handler` runs on the bridge's delivery thread.
final class Sink: EventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _connected = false
    private var _ownPn: String?
    var handler: (@Sendable (BridgeEvent) -> Void)?

    var connected: Bool { lock.withLock { _connected } }
    var ownPn: String? { lock.withLock { _ownPn } }

    func onEvents(events: [BridgeEvent]) {
        for e in events {
            lock.withLock {
                switch e {
                case .connection(.connected): _connected = true
                case .connection(.disconnected): _connected = false
                case let .ownJid(pn, _): if let pn { _ownPn = pn }
                default: break
                }
            }
            handler?(e)
        }
    }
}

func printStats(_ bridge: WaBridge) {
    let s = bridge.stats()
    err("stats: events_received=\(s.eventsReceived) events_dropped=\(s.eventsDropped) batches_flushed=\(s.batchesFlushed)")
}

func waitUntil(timeout: Double, _ cond: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return cond()
}

/// Renders a QR payload with Unicode half blocks (two modules per character row).
func renderQR(_ payload: String) -> String {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return payload }
    filter.setValue(Data(payload.utf8), forKey: "inputMessage")
    filter.setValue("L", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage,
          let cg = CIContext().createCGImage(image, from: image.extent) else { return payload }
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 255, count: w * h)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
    ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let quiet = 2
    func dark(_ x: Int, _ y: Int) -> Bool {
        let (xx, yy) = (x - quiet, y - quiet)
        guard xx >= 0, yy >= 0, xx < w, yy < h else { return false }
        return px[yy * w + xx] < 128
    }
    var out = ""
    for y in stride(from: 0, to: h + 2 * quiet, by: 2) {
        for x in 0..<(w + 2 * quiet) {
            switch (dark(x, y), dark(x, y + 1)) {
            case (true, true): out += " "
            case (true, false): out += "▄"
            case (false, true): out += "▀"
            case (false, false): out += "█"
            }
        }
        out += "\n"
    }
    return out
}

func makeBridge(_ sink: Sink) throws -> WaBridge {
    let level: LogLevel = switch ProcessInfo.processInfo.environment["WA_LOG"] {
    case "debug": .debug
    case "info": .info
    case "error": .error
    default: .warn
    }
    installLogger(sink: StderrLog(), maxLevel: level)
    return try WaBridge(dataDir: dataDir, sink: sink)
}

func connectAndWait(_ bridge: WaBridge, _ sink: Sink) async throws {
    try await bridge.connect()
    guard await waitUntil(timeout: 45, { sink.connected && sink.ownPn != nil }) else {
        throw CLIError("not connected after 45s (unpaired? run `wa-cli events` to link by QR)")
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var chatJids = Set<String>()
    var newestImage: BridgeMessage?
    var newestVoice: BridgeMessage?

    func add(_ key: String, _ n: Int = 1) { lock.withLock { counts[key, default: 0] += n } }
    func chats(_ jids: [String]) { lock.withLock { chatJids.formUnion(jids) } }
    func consider(_ m: BridgeMessage) {
        guard m.media != nil else { return }
        lock.withLock {
            if m.kind == .image, m.timestamp > (newestImage?.timestamp ?? 0) { newestImage = m }
            if m.kind == .voice, m.timestamp > (newestVoice?.timestamp ?? 0) { newestVoice = m }
        }
    }
    var summary: String {
        lock.withLock {
            var c = counts
            c["distinct_chats"] = chatJids.count
            c["distinct_lid_chats"] = chatJids.filter { $0.hasSuffix("@lid") }.count
            return c.keys.sorted().map { "\($0)=\(c[$0]!)" }.joined(separator: " ")
        }
    }

    func observe(_ e: BridgeEvent) {
        switch e {
        case let .historyChunk(chunk):
            add("history_chunks")
            add("chats", chunk.chats.count)
            add("messages", chunk.messages.count)
            add("updates", chunk.updates.count)
            add("contacts", chunk.contacts.count)
            add("aliases", chunk.aliases.count)
            chats(chunk.chats.map(\.jid))
            chunk.messages.forEach(consider)
        case let .messages(messages, updates):
            add("messages", messages.count)
            add("updates", updates.count)
            messages.forEach(consider)
        case let .contacts(contacts): add("contacts", contacts.count)
        case let .jidAliases(aliases): add("aliases", aliases.count)
        case let .chatAction(action):
            switch action {
            case .pin: add("action_pin")
            case .mute: add("action_mute")
            case .archive: add("action_archive")
            case .markRead: add("action_mark_read")
            default: add("action_other")
            }
        default: add("other_events")
        }
    }
}

final class ProgressPrinter: ProgressSink, @unchecked Sendable {
    let label: String
    init(_ label: String) { self.label = label }
    func onProgress(done: UInt64, total: UInt64) { err("  \(label): \(done)/\(total)") }
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// MARK: - Commands

func cmdEvents(_ args: [String]) async throws {
    let seconds = option("--seconds", in: args).flatMap(Double.init)
    let sink = Sink()
    sink.handler = { e in
        if case let .pairing(.qr(code, timeout)) = e {
            err("\n" + renderQR(code) + "Scan in WhatsApp → Linked Devices → Link a Device (valid \(timeout)s)\n")
        }
        print(bridgeEventJson(event: e))
        fflush(stdout)
    }
    let bridge = try makeBridge(sink)
    try await bridge.connect()
    if let nudge = option("--nudge-after", in: args).flatMap(Double.init) {
        DispatchQueue.main.asyncAfter(deadline: .now() + nudge) {
            err("nudging reconnect…")
            bridge.nudgeReconnect()
        }
    }

    let stop = AsyncStream<Void> { cont in
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { cont.yield() }
        src.resume()
        cont.onTermination = { _ in src.cancel() }
        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { cont.yield() }
        }
    }
    for await _ in stop { break }
    err("shutting down…")
    try await bridge.disconnect()
    printStats(bridge)
}

func cmdSendSelf(_ args: [String]) async throws {
    guard let text = args.first else { throw CLIError("usage: wa-cli send-self \"text\"") }
    let sink = Sink()
    sink.handler = { e in
        switch e {
        case .receipt, .messages: print(bridgeEventJson(event: e)); fflush(stdout)
        default: break
        }
    }
    let bridge = try makeBridge(sink)
    try await connectAndWait(bridge, sink)
    guard let me = sink.ownPn else { throw CLIError("own JID unknown") }
    let result = try await bridge.sendText(chat: me, text: text, replyTo: nil)
    err("sent \(result.messageId) to \(me)")
    try? await Task.sleep(for: .seconds(5))
    try await bridge.disconnect()
    printStats(bridge)
}

/// Prints progress in 10% steps; counts callbacks so tests can see progress was incremental.
final class PercentPrinter: ProgressSink, @unchecked Sendable {
    let label: String
    private let lock = NSLock()
    private var lastDecile = -1
    private(set) var calls = 0
    init(_ label: String) { self.label = label }
    func onProgress(done: UInt64, total: UInt64) {
        let decile = total > 0 ? Int(done * 10 / total) : 0
        let show = lock.withLock {
            calls += 1
            defer { lastDecile = decile }
            return decile != lastDecile
        }
        if show { err("  \(label): \(done)/\(total)") }
    }
}

final class IdSet: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func add(_ id: String) { lock.withLock { ids.append(id) } }
    func matches(_ s: String) -> Bool { lock.withLock { ids.contains { s.contains($0) } } }
}

func sha256Hex(_ url: URL) throws -> String {
    let h = Process()
    h.executableURL = URL(filePath: "/usr/bin/shasum")
    h.arguments = ["-a", "256", url.path]
    let pipe = Pipe()
    h.standardOutput = pipe
    try h.run()
    h.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
}

/// Sends files to your own number through the app's metadata path, then re-downloads each one and
/// checks the round trip (sha256, dimensions, duration, page count).
func cmdSendMediaSelf(_ args: [String]) async throws {
    let usage = "usage: wa-cli send-media-self FILE... [--kind image|video|gif|document] [--caption TEXT]"
    let kind = option("--kind", in: args)
    let caption = option("--caption", in: args)
    var files: [String] = []
    var i = 0
    while i < args.count {
        if args[i] == "--dry-run" { i += 1 } else if args[i].hasPrefix("--") { i += 2 } else { files.append(args[i]); i += 1 }
    }
    guard !files.isEmpty else { throw CLIError(usage) }

    var prepared: [PreparedAttachment] = []
    for f in files {
        let p = try await OutgoingMediaPreparer.prepare(URL(filePath: f), asDocument: kind == "document")
        if let kind, kind != "\(p.kind)" { throw CLIError("\(f) prepared as \(p.kind), not \(kind)") }
        let o = p.outgoing
        err("prepared \(f): kind=\(p.kind) file=\(o.filePath) mime=\(o.mimetype) name=\(o.fileName ?? "-") "
            + "size=\(o.width.map(String.init) ?? "-")x\(o.height.map(String.init) ?? "-") dur=\(o.durationSecs.map(String.init) ?? "-") "
            + "pages=\(o.pageCount.map(String.init) ?? "-") thumb=\(o.jpegThumbnail?.count ?? 0)B "
            + "thumbSize=\(o.thumbnailWidth.map(String.init) ?? "-")x\(o.thumbnailHeight.map(String.init) ?? "-")")
        prepared.append(p)
    }
    if args.contains("--dry-run") { return }

    let sentIds = IdSet()
    let sink = Sink()
    sink.handler = { e in
        guard case .receipt = e else { return }
        let json = bridgeEventJson(event: e)
        if sentIds.matches(json) { print(json); fflush(stdout) }
    }
    let bridge = try makeBridge(sink)
    try await connectAndWait(bridge, sink)
    guard let me = sink.ownPn else { throw CLIError("own JID unknown") }
    let out = URL(filePath: NSTemporaryDirectory()).appending(path: "wa-cli-roundtrip")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    for (n, p) in prepared.enumerated() {
        var o = p.outgoing
        o.caption = n == 0 ? caption : nil
        let progress = PercentPrinter("upload \(p.fileURL.lastPathComponent)")
        let start = Date()
        let result = try await bridge.sendMedia(chat: me, media: o, replyTo: nil, progress: progress)
        sentIds.add(result.messageId)
        guard let m = result.message.media else { throw CLIError("send result has no media") }
        err("sent \(result.messageId) kind=\(result.message.kind) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s, "
            + "\(progress.calls) progress callbacks, fileLength=\(m.fileLength) animated=\(m.isAnimated ?? false)")

        let ext = p.fileURL.pathExtension.isEmpty ? "bin" : p.fileURL.pathExtension
        let back = out.appending(path: "\(result.messageId).\(ext)")
        try await bridge.downloadMedia(media: m, destPath: back.path, progress: nil)
        let sentSha = try sha256Hex(p.fileURL), backSha = try sha256Hex(back)
        let again = try await OutgoingMediaPreparer.prepare(back, asDocument: p.kind == .document).outgoing
        print("roundtrip \(result.messageId): sha256 \(sentSha == backSha ? "MATCH" : "MISMATCH") \(backSha) "
              + "size=\(again.width.map(String.init) ?? "-")x\(again.height.map(String.init) ?? "-") "
              + "dur=\(again.durationSecs.map(String.init) ?? "-") pages=\(again.pageCount.map(String.init) ?? "-") "
              + "mime=\(m.mimetype ?? "-") name=\(m.fileName ?? "-") → \(back.path)")
        fflush(stdout)
        if p.isConverted { try? FileManager.default.removeItem(at: p.fileURL) }
    }
    try? await Task.sleep(for: .seconds(6))
    try await bridge.disconnect()
    printStats(bridge)
}

func cmdImport(_ args: [String]) async throws {
    let dir = args.first ?? captureDir
    let counter = Counter()
    let sink = Sink()
    sink.handler = { counter.observe($0) }
    let bridge = try makeBridge(sink)
    let start = Date()
    try await bridge.importCapture(captureDir: dir)
    print("import-capture \(dir) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
    print(counter.summary)
    printStats(bridge)
}

final class BatchSink: EventSink, @unchecked Sendable {
    let continuation: AsyncStream<[BridgeEvent]>.Continuation
    init(_ c: AsyncStream<[BridgeEvent]>.Continuation) { continuation = c }
    func onEvents(events: [BridgeEvent]) { continuation.yield(events) }
}

func cmdIngest(_ args: [String]) async throws {
    let dbURL = option("--db", in: args).map { URL(filePath: $0) } ?? AppDatabase.defaultURL
    try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let ingest = try IngestActor(database: try AppDatabase(url: dbURL))
    let (stream, cont) = AsyncStream<[BridgeEvent]>.makeStream(bufferingPolicy: .unbounded)
    let bridge = try WaBridge(dataDir: dataDir, sink: BatchSink(cont))
    let start = Date()
    let applier = Task {
        var batches = 0
        for await batch in stream {
            try await ingest.apply(batch)
            batches += 1
        }
        return batches
    }
    try await bridge.importCapture(captureDir: captureDir)
    cont.finish()
    let batches = try await applier.value
    print("ingested \(batches) batches into \(dbURL.path) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
}

func cmdDownload(_ args: [String]) async throws {
    let out = option("--out", in: args) ?? NSTemporaryDirectory() + "wa-cli"
    let counter = Counter()
    let sink = Sink()
    sink.handler = { counter.observe($0) }
    let bridge = try makeBridge(sink)
    try await bridge.importCapture(captureDir: captureDir)
    guard let image = counter.newestImage, let voice = counter.newestVoice else {
        throw CLIError("capture has no image or voice note with media")
    }
    sink.handler = nil
    try await connectAndWait(bridge, sink)
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

    let imagePath = "\(out)/\(image.id).jpg"
    err("image \(image.id) in \(image.chatJid) (\(image.media!.fileLength) bytes)")
    try await bridge.downloadMedia(media: image.media!, destPath: imagePath, progress: ProgressPrinter("image"))
    print("image: \(imagePath)")

    let oggPath = "\(out)/\(voice.id).ogg"
    let cafPath = "\(out)/\(voice.id).caf"
    err("voice \(voice.id) in \(voice.chatJid) (\(voice.media!.fileLength) bytes, \(voice.media!.durationSecs ?? 0)s)")
    try await bridge.downloadMedia(media: voice.media!, destPath: oggPath, progress: ProgressPrinter("voice"))
    try remuxOggToCaf(src: oggPath, dst: cafPath)
    print("voice: \(oggPath)")
    print("caf: \(cafPath)")
    try await bridge.disconnect()
    printStats(bridge)
}

// MARK: - Main

let argv = Array(CommandLine.arguments.dropFirst())
do {
    switch argv.first {
    case "events": try await cmdEvents(Array(argv.dropFirst()))
    case "send-self": try await cmdSendSelf(Array(argv.dropFirst()))
    case "send-media-self": try await cmdSendMediaSelf(Array(argv.dropFirst()))
    case "import-capture": try await cmdImport(Array(argv.dropFirst()))
    case "download": try await cmdDownload(Array(argv.dropFirst()))
    case "ingest-capture": try await cmdIngest(Array(argv.dropFirst()))
    case "migrate":
        guard let path = option("--db", in: Array(argv.dropFirst())) else { throw CLIError("usage: wa-cli migrate --db PATH") }
        _ = try AppDatabase(url: URL(filePath: path))
        print("migrated \(path)")
    case "qr":
        guard argv.count == 2 else { throw CLIError("usage: wa-cli qr TEXT") }
        print(renderQR(argv[1]), terminator: "")
    case "remux":
        guard argv.count == 3 else { throw CLIError("usage: wa-cli remux SRC DST") }
        try remuxOggToCaf(src: argv[1], dst: argv[2])
    default:
        err("usage: wa-cli events [--seconds N] [--nudge-after N] | qr TEXT | send-self TEXT | send-media-self FILE... [--kind K] [--caption T] | download [--out DIR] | import-capture [DIR] | ingest-capture [--db PATH] | migrate --db PATH | remux SRC DST")
        exit(2)
    }
} catch {
    err("error: \(error)")
    exit(1)
}
