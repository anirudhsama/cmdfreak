import AppKit
import Observation
import WAKit

/// Per-row model the SwiftUI row observes. One instance lives per chat for as long as the chat is
/// in the list; a reused collection item is re-pointed at a different state instead of rebuilding
/// its hosting view. Everything displayable is precomputed here, so the row body does no work
/// beyond reading fields.
@MainActor @Observable
final class ChatRowState: Identifiable {
    let jid: String
    private(set) var item: ChatListItem

    private(set) var title = ""
    private(set) var initials = ""
    private(set) var time = ""
    private(set) var isGroup = false
    private(set) var isPinned = false
    private(set) var isMuted = false
    private(set) var unreadCount = 0
    private(set) var markedUnread = false
    /// "You" or the group sender's name, rendered before the preview.
    private(set) var previewPrefix: String?
    /// SF Symbol shown before the preview text for media and other non-text kinds.
    private(set) var previewSymbol: String?
    private(set) var previewText = ""
    private(set) var previewIsPlaceholder = false
    private(set) var avatarPath: String?
    var avatar: CGImage?
    var isTyping = false
    var isSelected = false

    var showsUnread: Bool { unreadCount > 0 || markedUnread }

    init(item: ChatListItem) {
        jid = item.chat.jid
        self.item = item
        apply(item, force: true)
    }

    func apply(_ item: ChatListItem, force: Bool = false) {
        guard force || item != self.item else { return }
        self.item = item
        let chat = item.chat
        title = item.title
        initials = Initials.from(item.title)
        isGroup = chat.kind == .group
        isPinned = chat.isPinned
        isMuted = chat.isMuted()
        unreadCount = chat.unreadCount
        markedUnread = chat.markedUnread
        time = chat.lastActivityAt.map { ChatTimeFormatter.string(fromUnixSeconds: $0) } ?? ""
        if avatarPath != chat.avatarPath {
            avatarPath = chat.avatarPath
            avatar = nil
        }
        applyPreview(item.preview)
    }

    private func applyPreview(_ preview: ChatPreview?) {
        guard let preview else {
            previewPrefix = nil
            previewSymbol = nil
            previewText = ""
            previewIsPlaceholder = true
            return
        }
        previewPrefix = preview.fromMe ? "You" : preview.senderName
        if preview.revoked {
            previewSymbol = "nosign"
            previewText = "This message was deleted"
            previewIsPlaceholder = true
            return
        }
        let text = preview.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let (symbol, label): (String?, String) = switch preview.kind {
        case .text: (nil, "")
        case .image: ("photo", "Photo")
        case .video: ("video", "Video")
        case .gif: ("photo.stack", "GIF")
        case .sticker: ("face.smiling", "Sticker")
        case .document: ("doc", "Document")
        case .audio: ("waveform", "Audio")
        case .voice: ("mic", "Voice message")
        case .location: ("mappin.and.ellipse", "Location")
        case .contact: ("person.crop.square", "Contact")
        case .poll: ("chart.bar", "Poll")
        case .system: ("info.circle", "")
        case .undecryptable: ("lock", "Waiting for this message")
        case .unsupported: ("questionmark.square.dashed", "Unsupported message")
        }
        previewSymbol = symbol
        previewText = text.isEmpty ? label : text
        previewIsPlaceholder = text.isEmpty && preview.kind != .text
    }
}

/// Shared by every row: whether selection should draw emphasized (list focused in a key window).
@MainActor @Observable
final class ChatListAppearance {
    var isEmphasized = false
}
