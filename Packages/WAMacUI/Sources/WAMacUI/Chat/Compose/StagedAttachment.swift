import AppKit
import UniformTypeIdentifiers
import WAKit

/// One file in the compose tray: its metadata task and, once done, the result.
@MainActor
struct StagedAttachment {
    let id = UUID()
    let source: URL
    let task: Task<PreparedAttachment, any Error>
    var result: Result<PreparedAttachment, any Error>?

    /// Cancels preparation (e.g. a video transcode) and removes a converted copy (GIF→MP4, HEIC→JPEG,
    /// pasted image) that will never be sent. The owner ignores the result of a discarded item.
    func discard() {
        let task = task
        task.cancel()
        let source = source
        Task.detached {
            if let p = try? await task.value, p.isConverted { try? FileManager.default.removeItem(at: p.fileURL) }
            if source.path.hasPrefix(OutgoingMediaPreparer.stagingDirectory.path) { try? FileManager.default.removeItem(at: source) }
        }
    }

    var trayItem: AttachmentTrayView.Item {
        let name = source.lastPathComponent
        switch result {
        case nil:
            return .init(id: id, name: name, image: NSWorkspace.shared.icon(forFile: source.path), isDocument: true, badge: nil, state: .preparing)
        case .failure(let error):
            return .init(id: id, name: name, image: NSWorkspace.shared.icon(forFile: source.path), isDocument: true, badge: nil,
                         state: .failed(error.localizedDescription))
        case .success(let p):
            let preview = p.preview.flatMap(NSImage.init(data:))
            let badge: String? = switch p.kind {
            case .gif: "GIF"
            case .video: p.outgoing.durationSecs.map { Self.duration(Int($0)) }
            default: nil
            }
            let icon = preview ?? NSWorkspace.shared.icon(forFile: source.path)
            return .init(id: id, name: name, image: icon, isDocument: preview == nil,
                         badge: badge, state: .ready)
        }
    }

    static func duration(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The chat view's root: accepts files (and image data) dragged anywhere over the chat and shows a
/// drop highlight while a drag hovers.
final class AttachmentDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var acceptsDrops: () -> Bool = { true }
    private let highlight = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(PasteboardAttachments.dragTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setHighlighted(_ on: Bool) {
        guard let layer else { return }
        if on {
            highlight.frame = bounds.insetBy(dx: 8, dy: 8)
            highlight.cornerRadius = 14
            highlight.borderWidth = 2
            highlight.borderColor = NSColor.controlAccentColor.cgColor
            highlight.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            highlight.zPosition = 1000
            if highlight.superlayer == nil { layer.addSublayer(highlight) }
        } else {
            highlight.removeFromSuperlayer()
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrops(), PasteboardAttachments.canRead(sender.draggingPasteboard) else { return [] }
        setHighlighted(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setHighlighted(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setHighlighted(false)
        let urls = PasteboardAttachments.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
