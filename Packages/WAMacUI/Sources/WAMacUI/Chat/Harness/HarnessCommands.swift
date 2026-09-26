#if DEBUG
import AppKit
import Quartz
import ImageIO
import UniformTypeIdentifiers

/// Scriptable control for the harness: lines written to `/tmp/wa-harness-cmd` are executed and the
/// file is removed. Lets an agent drive and screenshot the view without Accessibility permissions.
///
///   shot PATH            self-capture the window to PNG
///   dark | light         switch appearance
///   open dm|group        switch chats
///   send TEXT            put TEXT in compose and send
///   type TEXT            insert into compose (keeps focus)
///   attach P1|P2         stage files in the attachment tray
///   sendstaged           send the tray with the compose text as caption ("fail" in it fails the upload once)
///   retry N              retry the failed send at row N
///   incoming TEXT        deliver an incoming message to the open chat
///   scroll DY            scroll the list by DY points (negative = up)
///   top | bottom         jump to the top of the loaded window / the bottom
///   resize W H           resize the window
///   esc | up | select N  keyboard-equivalents: Esc, ↑ in empty compose, select row N
///   reply N | react N E  reply to / react E on the message at row N
///   click N              click the media of the message at row N (download / Quick Look)
///   ql                   Quick Look the selected row
///   reload               push a `.reload` change through the list pipeline
///   focuslist            make the table first responder
@MainActor
enum HarnessCommands {
    static let path = "/tmp/wa-harness-cmd"
    private static var timer: Timer?

    static func start(window: NSWindow, controller: ChatViewController, open: @escaping @MainActor (String) -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(atPath: path)
                for line in text.split(separator: "\n") {
                    NSLog("harness: run \(line)")
                    run(String(line), window: window, controller: controller, open: open)
                }
            }
        }
    }

    private static func run(_ line: String, window: NSWindow, controller: ChatViewController, open: (String) -> Void) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        let list = controller.listController
        switch cmd {
        case "shot": shot(window, to: arg)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "open": open(arg == "group" ? ChatHarness.group : ChatHarness.dm)
        case "send":
            controller.insertComposeText(arg)
            controller.debugSend()
        case "type": controller.insertComposeText(arg)
        case "attach": controller.attach(arg.split(separator: "|").map { URL(filePath: String($0)) })
        case "sendstaged": controller.debugSend()
        case "retry": if let n = Int(arg), let item = list.rows.item(atRow: n) { controller.retry(item) }
        case "incoming": ChatHarness.deliverIncoming(text: arg, chat: controller.chatJid ?? ChatHarness.dm)
        case "scroll":
            let clip = list.scrollView.contentView
            clip.setBoundsOrigin(NSPoint(x: 0, y: clip.bounds.origin.y + CGFloat(Double(arg) ?? 0)))
            list.scrollView.reflectScrolledClipView(clip)
        case "top":
            let clip = list.scrollView.contentView
            clip.setBoundsOrigin(NSPoint(x: 0, y: -list.scrollView.contentInsets.top))
            list.scrollView.reflectScrolledClipView(clip)
        case "bottom": list.scrollToBottom()
        case "resize":
            let d = arg.split(separator: " ").compactMap { Double($0) }
            if d.count == 2 { window.setContentSize(NSSize(width: d[0], height: d[1])) }
        case "esc": controller.escapeFromList()
        case "up": controller.debugArrowUp()
        case "select":
            if let n = Int(arg) {
                list.tableView.selectRowIndexes(IndexSet(integer: n), byExtendingSelection: false)
                window.makeFirstResponder(list.tableView)
            }
        case "reply": if let n = Int(arg), let item = list.rows.item(atRow: n) { controller.reply(to: item) }
        case "react":
            let p = arg.split(separator: " ").map(String.init)
            if p.count == 2, let n = Int(p[0]), let item = list.rows.item(atRow: n) { controller.toggleReaction(p[1], on: item) }
        case "click": if let n = Int(arg), let item = list.rows.item(atRow: n) { list.open(item) }
        case "ql": list.quickLookSelection()
        case "reload": list.debugInjectReload()
        case "focuslist": window.makeFirstResponder(list.tableView)
        case "play":
            if let n = Int(arg), let item = list.rows.item(atRow: n) {
                AudioPlaybackController.shared.toggle(item, media: controller.client.media)
            }
        case "status":
            let clip = list.scrollView.contentView
            let visible = list.tableView.rows(in: list.tableView.visibleRect)
            let audio = AudioPlaybackController.shared.state
            let s = """
            rows=\(list.rows.count) messages=\(list.rows.messages.count) hasOlder=\(list.rows.hasOlder) hasNewer=\(list.rows.hasNewer)
            atBottom=\(list.isAtBottom) visible=\(visible.location)..<\(visible.location + visible.length) originY=\(clip.bounds.origin.y) docH=\(list.tableView.frame.height)
            ql=\(QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible)
            audio=\(audio.map { "\($0.messageId) playing=\($0.isPlaying) loading=\($0.isLoading) elapsed=\($0.elapsed) dur=\($0.duration) rate=\($0.rate)" } ?? "nil")
            compose=\(controller.isComposeFocused) bar=\(String(describing: controller.debugBar)) text=\(controller.debugComposeText)
            syncPlanFallbacks=\(list.debugSyncPlanFallbacks) loadingOlder=\(list.debugLoadingFlags.older) loadingNewer=\(list.debugLoadingFlags.newer)
            """
            try? s.write(toFile: "/tmp/wa-harness-status.txt", atomically: true, encoding: .utf8)
        case "rows":
            var s = ""
            for i in 0..<list.rows.count { s += "\(i): \(list.rows.row(at: i)!)\n" }
            try? s.write(toFile: "/tmp/wa-harness-rows.txt", atomically: true, encoding: .utf8)
        default: NSLog("harness: unknown command \(line)")
        }
    }

    /// Renders the window content ourselves; other-process capture needs Screen Recording permission.
    private static func shot(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        window.displayIfNeeded()
        CATransaction.flush()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else {
            NSLog("harness: capture failed")
            return
        }
        guard let dest = CGImageDestinationCreateWithURL(URL(filePath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
#endif
