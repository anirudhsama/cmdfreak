import AppKit
import WAKit

/// Everything a `MessageCell` needs to lay itself out and draw without measuring anything.
/// Frames are in flipped row coordinates (origin top-left). Immutable once built, so it is safe to
/// build off the main thread and share; the attributed strings are never mutated after creation.
struct LayoutPlan: @unchecked Sendable {
    enum Shape: Sendable {
        case bubble
        /// Stickers: no bubble background.
        case bare
        /// Centered pill (system messages).
        case system
    }

    struct Label: @unchecked Sendable {
        let text: NSAttributedString
        let frame: CGRect
    }

    struct Quote: @unchecked Sendable {
        let frame: CGRect
        let name: NSAttributedString
        let snippet: NSAttributedString
        let color: NSColor
        let targetId: String
    }

    struct Media: Sendable {
        enum Kind: Sendable { case image, video, gif }
        let kind: Kind
        let frame: CGRect
        /// `ThumbnailCache` key for the embedded JPEG thumbnail, and for the full file when local.
        let thumbKey: String
        let fileKey: String
        let durationText: String?
        let pixelSize: Int
    }

    struct Document: @unchecked Sendable {
        let frame: CGRect
        let name: NSAttributedString
        let detail: NSAttributedString
        let fileName: String
    }

    struct Audio: Sendable {
        let frame: CGRect
        let durationText: String
        let isVoice: Bool
        /// 0…1 samples for the waveform.
        let waveform: [Float]
    }

    struct Card: @unchecked Sendable {
        enum Kind: Sendable { case location, contact }
        let kind: Kind
        let frame: CGRect
        let title: NSAttributedString
        let subtitle: NSAttributedString
        let symbol: String
    }

    struct Poll: @unchecked Sendable {
        struct Option: @unchecked Sendable {
            let label: NSAttributedString
            let count: NSAttributedString
            let fraction: Double
            let mine: Bool
            let frame: CGRect
        }
        let frame: CGRect
        let question: Label
        let options: [Option]
        let footer: Label
    }

    enum Content: Sendable {
        case none
        case media(Media)
        case sticker(frame: CGRect, fileKey: String, thumbKey: String, animated: Bool)
        case document(Document)
        case audio(Audio)
        case card(Card)
        case poll(Poll)
    }

    struct Meta: Sendable {
        let frame: CGRect
        let text: String
        let status: MessageStatus?
        /// Drawn over media (light text on a dark capsule).
        let overlay: Bool
    }

    struct Chip: Sendable {
        let emoji: String
        let count: Int
        let mine: Bool
        let frame: CGRect
    }

    let id: String
    let width: CGFloat
    let rowHeight: CGFloat
    let outgoing: Bool
    let shape: Shape
    let bubble: CGRect
    let sender: Label?
    let forwarded: Label?
    let quote: Quote?
    let content: Content
    /// Body, caption, or placeholder text (revoked, undecryptable, unsupported).
    let text: Label?
    let meta: Meta?
    let reactions: [Chip]
    let isFailed: Bool
    /// Tail on the last message of a run.
    let hasTail: Bool
}

/// Per-row context that changes the plan but is not part of the message.
struct RowContext: Hashable, Sendable {
    var width: CGFloat
    var isGroupChat: Bool
    var showsSender: Bool
    var isFirstInGroup: Bool
    var isLastInGroup: Bool
    var ownJid: String?
    /// DM peer's display name, used for quoted-reply headers.
    var peerName: String?
    /// Display name of the quoted message's sender when known from the loaded window.
    var quotedSenderName: String?
}

extension LayoutPlan {
    /// Cache key: message id + content + context. `MessageItem` hashing covers status, media
    /// state, reactions, edits and revokes.
    static func cacheKey(_ item: MessageItem, _ ctx: RowContext) -> String {
        var h = Hasher()
        h.combine(item)
        h.combine(ctx)
        return "\(item.id)#\(h.finalize())"
    }
}
