import AppKit
import WAKit

/// Builds `LayoutPlan`s. Pure and thread-safe: no UI objects other than fonts/colors/attributed strings.
enum LayoutPlanner {
    typealias M = MessageTextConfiguration.Metrics
    typealias C = MessageTextConfiguration

    private static let timeFormat = Date.FormatStyle(date: .omitted, time: .shortened)
    private static let sizeFormat = ByteCountFormatStyle(style: .file)

    static func timeText(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(timeFormat)
    }

    static func durationText(_ secs: Int) -> String {
        String(format: "%d:%02d", secs / 60, secs % 60)
    }

    // MARK: - Entry

    static func plan(_ item: MessageItem, _ ctx: RowContext) -> LayoutPlan {
        let m = item.message
        if m.kind == .system { return systemPlan(item, ctx) }
        return bubblePlan(item, ctx)
    }

    // MARK: - System

    private static func systemPlan(_ item: MessageItem, _ ctx: RowContext) -> LayoutPlan {
        let text = item.message.text ?? item.message.typeName ?? "System message"
        let attr = NSAttributedString(string: text, attributes: [
            .font: C.system, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: C.paragraph,
        ])
        let maxW = min(ctx.width - 2 * M.horizontalInset, 460) - 2 * M.systemPaddingH
        let r = TextMeasurer.measure(attr, width: maxW)
        let pillW = r.size.width + 2 * M.systemPaddingH
        let pillH = r.size.height + 2 * M.systemPaddingV
        let top = M.messageGap
        let pill = CGRect(x: (ctx.width - pillW) / 2, y: top, width: pillW, height: pillH).integral
        let label = LayoutPlan.Label(text: attr, frame: pill.insetBy(dx: M.systemPaddingH, dy: M.systemPaddingV))
        return LayoutPlan(
            id: item.id, width: ctx.width, rowHeight: pill.maxY + 2, outgoing: false, shape: .system, bubble: pill,
            sender: nil, avatar: nil, forwarded: nil, quote: nil, content: .none, text: label, meta: nil, reactions: [],
            isFailed: false, hasTail: false)
    }

    // MARK: - Bubble

    private static func bubblePlan(_ item: MessageItem, _ ctx: RowContext) -> LayoutPlan {
        let m = item.message
        let outgoing = m.fromMe
        let indent = ctx.isGroupChat && !outgoing ? M.groupAvatarIndent : 0
        let leading = M.horizontalInset + indent
        let maxBubble = min(floor((ctx.width - indent) * M.bubbleMaxWidthFraction), M.bubbleMaxWidth)
        let innerMax = maxBubble - 2 * M.bubblePaddingH
        let isSticker = m.kind == .sticker && !m.revoked

        // Meta (time + ticks + edited)
        var metaText = timeText(m.timestamp)
        if m.editedAt != nil, !m.revoked { metaText = "edited · " + metaText }
        let status: MessageStatus? = outgoing ? m.status : nil
        let metaW = TextMeasurer.width(metaText, font: C.meta) + (status != nil ? M.tickWidth + 2 : 0)

        let y: CGFloat = ctx.isFirstInGroup ? M.messageGap : M.groupGap
        var contentY = M.bubblePaddingV
        var innerWidth: CGFloat = 0  // widest part, excluding bubble padding
        var sender: LayoutPlan.Label?
        var forwarded: LayoutPlan.Label?
        var quote: LayoutPlan.Quote?
        var content: LayoutPlan.Content = .none
        var text: LayoutPlan.Label?
        var meta: LayoutPlan.Meta?
        let bubbleTop = y

        // Sender name (groups, incoming, first of run)
        if ctx.showsSender, !outgoing, let name = item.senderName, !isSticker {
            let attr = NSAttributedString(string: name, attributes: [
                .font: C.sender, .foregroundColor: C.senderColor(for: m.senderJid),
            ])
            let w = min(TextMeasurer.width(name, font: C.sender), innerMax)
            sender = .init(text: attr, frame: CGRect(x: M.bubblePaddingH, y: contentY, width: w, height: M.senderHeight))
            innerWidth = max(innerWidth, w)
            contentY += M.senderHeight + 1
        }

        if m.isForwarded, !m.revoked, !isSticker {
            let attr = NSAttributedString(string: "Forwarded", attributes: [
                .font: NSFontManager.shared.convert(C.meta, toHaveTrait: .italicFontMask),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            forwarded = .init(text: attr, frame: CGRect(x: M.bubblePaddingH, y: contentY, width: 80, height: M.metaHeight))
            innerWidth = max(innerWidth, 70)
            contentY += M.metaHeight + 2
        }

        // Quoted reply
        if let qid = m.quotedId, !m.revoked, !isSticker {
            let qName = quoteName(m, ctx)
            let snippet = quoteSnippet(m, item.displayQuotedSnippet)
            let nameAttr = NSAttributedString(string: qName, attributes: [.font: C.quoteName, .foregroundColor: C.senderColor(for: m.quotedSenderJid ?? "me")])
            let snipAttr = NSAttributedString(string: snippet, attributes: [.font: C.quoteBody, .foregroundColor: NSColor.secondaryLabelColor])
            let w = min(innerMax, max(180, TextMeasurer.width(snippet, font: C.quoteBody) + 24, TextMeasurer.width(qName, font: C.quoteName) + 24))
            quote = .init(frame: CGRect(x: M.bubblePaddingH, y: contentY, width: w, height: M.quoteHeight),
                          name: nameAttr, snippet: snipAttr, color: C.senderColor(for: m.quotedSenderJid ?? "me"), targetId: qid)
            innerWidth = max(innerWidth, w)
            contentY += M.quoteHeight + 6
        }

        // Body / placeholder text
        var bodyAttr: NSAttributedString?
        var metaInline = false
        if m.revoked {
            bodyAttr = placeholder("This message was deleted.", symbolic: true)
        } else {
            switch m.kind {
            case .undecryptable:
                bodyAttr = placeholder("Waiting for this message. This may take a while.", symbolic: true)
            case .unsupported:
                bodyAttr = placeholder("Unsupported message (\(m.typeName ?? "unknown")) — open on phone.", symbolic: true)
            case .text:
                let t = item.displayText ?? ""
                if MarkdownLite.isEmojiOnly(t) {
                    bodyAttr = NSAttributedString(string: t, attributes: [.font: C.bigEmoji, .paragraphStyle: C.paragraph])
                } else {
                    bodyAttr = MarkdownLite.attributedString(t)
                }
            case .poll:
                break  // the question is part of the card
            default:
                if let t = item.displayText, !t.isEmpty { bodyAttr = MarkdownLite.attributedString(t) }
            }
        }

        // Kind-specific content
        let media = item.media
        var mediaFrame: CGRect?
        let mediaCaptioned = bodyAttr != nil
        if !m.revoked {
            switch m.kind {
            case .image, .video, .gif:
                let (frame, size) = mediaFrameFor(media, maxWidth: maxBubble - 2 * M.mediaInset, contentY: contentY)
                let kind: LayoutPlan.Media.Kind = m.kind == .image ? .image : (m.kind == .gif ? .gif : .video)
                content = .media(.init(
                    kind: kind, frame: frame, thumbKey: thumbKey(item), fileKey: fileKey(item),
                    durationText: media?.durationSecs.map(durationText), pixelSize: size))
                mediaFrame = frame
                innerWidth = max(innerWidth, frame.width + 2 * M.mediaInset - 2 * M.bubblePaddingH)
                contentY = frame.maxY + (mediaCaptioned ? 6 : 0)
            case .sticker:
                let f = CGRect(x: 0, y: y, width: M.stickerSize, height: M.stickerSize)
                content = .sticker(frame: f, fileKey: fileKey(item), thumbKey: thumbKey(item), animated: media?.isAnimated ?? false)
            case .document:
                let f = CGRect(x: M.bubblePaddingH, y: contentY, width: min(M.cardWidth, innerMax), height: M.documentHeight)
                content = .document(documentPlan(media, frame: f))
                innerWidth = max(innerWidth, f.width)
                contentY = f.maxY + (mediaCaptioned ? 6 : 4)
            case .audio, .voice:
                let f = CGRect(x: M.bubblePaddingH, y: contentY, width: min(M.cardWidth, innerMax), height: M.audioHeight)
                content = .audio(.init(frame: f, durationText: durationText(media?.durationSecs ?? 0),
                                       isVoice: m.kind == .voice, waveform: waveform(media?.waveform)))
                innerWidth = max(innerWidth, f.width)
                contentY = f.maxY + 4
            case .location:
                let loc = m.extra?.location
                let title = loc?.isLive == true ? "Live location" : (loc?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Location")
                let sub = loc?.address.flatMap { $0.isEmpty ? nil : $0 } ?? loc.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) } ?? ""
                let f = CGRect(x: M.bubblePaddingH, y: contentY, width: min(M.cardWidth, innerMax), height: M.documentHeight)
                content = .card(cardPlan(.location, frame: f, title: title, subtitle: sub, symbol: "mappin.and.ellipse"))
                innerWidth = max(innerWidth, f.width)
                contentY = f.maxY + 4
            case .contact:
                let name = m.extra?.contact?.displayName ?? "Contact"
                let f = CGRect(x: M.bubblePaddingH, y: contentY, width: min(M.cardWidth, innerMax), height: M.documentHeight)
                content = .card(cardPlan(.contact, frame: f, title: name, subtitle: "Contact card", symbol: "person.crop.circle"))
                innerWidth = max(innerWidth, f.width)
                contentY = f.maxY + 4
            case .poll:
                let p = pollPlan(item, ctx, x: M.bubblePaddingH, y: contentY, width: min(M.cardWidth, innerMax))
                content = .poll(p)
                innerWidth = max(innerWidth, p.frame.width)
                contentY = p.frame.maxY + 4
            default:
                break
            }
        }

        // Text and meta placement
        if isSticker {
            let f = CGRect(x: 0, y: y + M.stickerSize + 2, width: metaW, height: M.metaHeight)
            meta = .init(frame: f, text: metaText, status: status, overlay: false)
            let bubble = CGRect(x: outgoing ? ctx.width - M.horizontalInset - M.stickerSize : leading, y: y,
                                width: M.stickerSize, height: M.stickerSize)
            var rowH = f.maxY + 2
            let chips = chips(item, ctx, bubble: bubble, outgoing: outgoing, bottom: &rowH)
            return LayoutPlan(id: item.id, width: ctx.width, rowHeight: rowH, outgoing: outgoing, shape: .bare, bubble: bubble,
                              sender: nil, avatar: avatarPlan(item, ctx, bubble: bubble), forwarded: nil, quote: nil,
                              content: shift(content, dx: bubble.minX, dy: 0), text: nil,
                              meta: shift(meta!, dx: bubble.minX + (outgoing ? M.stickerSize - metaW : 0), dy: 0),
                              reactions: chips, isFailed: m.status == .failed, hasTail: false)
        }

        if let bodyAttr {
            let r = TextMeasurer.measure(bodyAttr, width: innerMax)
            let textW = r.size.width
            if r.lastLineWidth + M.metaGap + metaW <= innerMax {
                metaInline = true
                innerWidth = max(innerWidth, max(textW, r.lastLineWidth + M.metaGap + metaW))
            } else {
                innerWidth = max(innerWidth, textW, metaW)
            }
            text = .init(text: bodyAttr, frame: CGRect(x: M.bubblePaddingH, y: contentY, width: textW, height: r.size.height))
            contentY += r.size.height
            if metaInline {
                meta = .init(frame: CGRect(x: 0, y: contentY - M.metaHeight, width: metaW, height: M.metaHeight),
                             text: metaText, status: status, overlay: false)
            } else {
                contentY += 2
                meta = .init(frame: CGRect(x: 0, y: contentY, width: metaW, height: M.metaHeight), text: metaText, status: status, overlay: false)
                contentY += M.metaHeight
            }
        } else if let mediaFrame {
            // Overlay meta on the media, bottom-right.
            meta = .init(frame: CGRect(x: mediaFrame.maxX - metaW - 12, y: mediaFrame.maxY - M.metaHeight - 8, width: metaW, height: M.metaHeight),
                         text: metaText, status: status, overlay: true)
            contentY = mediaFrame.maxY
        } else {
            innerWidth = max(innerWidth, metaW)
            meta = .init(frame: CGRect(x: 0, y: contentY, width: metaW, height: M.metaHeight), text: metaText, status: status, overlay: false)
            contentY += M.metaHeight
        }

        // Bubble frame
        let hasMediaOnly = mediaFrame != nil && !mediaCaptioned && sender == nil && quote == nil && forwarded == nil
        var bubbleW = max(M.bubbleMinWidth, innerWidth + 2 * M.bubblePaddingH)
        if let mediaFrame { bubbleW = max(bubbleW, mediaFrame.width + 2 * M.mediaInset) }
        bubbleW = min(bubbleW, maxBubble)
        var bubbleH = contentY + (hasMediaOnly ? M.mediaInset : M.bubblePaddingV)
        if case .media = content, mediaFrame != nil, hasMediaOnly { bubbleH = mediaFrame!.maxY + M.mediaInset }
        let bubbleX = outgoing ? ctx.width - M.horizontalInset - bubbleW : leading
        let bubble = CGRect(x: bubbleX, y: bubbleTop, width: bubbleW, height: bubbleH).integral

        // Right-align meta within the bubble (or the media overlay).
        if var mp = meta, !mp.overlay {
            mp = .init(frame: CGRect(x: bubbleW - M.bubblePaddingH - metaW, y: mp.frame.minY, width: metaW, height: M.metaHeight),
                       text: mp.text, status: mp.status, overlay: false)
            meta = mp
        }
        // Widen full-width parts (quote, media) to the bubble's inner width.
        if let q = quote {
            quote = .init(frame: CGRect(x: q.frame.minX, y: q.frame.minY, width: bubbleW - 2 * M.bubblePaddingH, height: q.frame.height),
                          name: q.name, snippet: q.snippet, color: q.color, targetId: q.targetId)
        }
        if case .media(let md) = content {
            let f = CGRect(x: M.mediaInset, y: md.frame.minY, width: bubbleW - 2 * M.mediaInset, height: md.frame.height)
            content = .media(.init(kind: md.kind, frame: f, thumbKey: md.thumbKey, fileKey: md.fileKey,
                                   durationText: md.durationText, pixelSize: md.pixelSize))
            if var mp = meta, mp.overlay {
                mp = .init(frame: CGRect(x: f.maxX - metaW - 10, y: f.maxY - M.metaHeight - 6, width: metaW, height: M.metaHeight),
                           text: mp.text, status: mp.status, overlay: true)
                meta = mp
            }
        }

        // Everything so far is bubble-relative; convert to row coordinates.
        var rowH = bubble.maxY
        let chipPlans = chips(item, ctx, bubble: bubble, outgoing: outgoing, bottom: &rowH)
        rowH += ctx.isLastInGroup ? 2 : 0

        return LayoutPlan(
            id: item.id, width: ctx.width, rowHeight: ceil(rowH), outgoing: outgoing, shape: .bubble, bubble: bubble,
            sender: sender.map { shift($0, dx: bubble.minX, dy: bubble.minY) },
            avatar: avatarPlan(item, ctx, bubble: bubble),
            forwarded: forwarded.map { shift($0, dx: bubble.minX, dy: bubble.minY) },
            quote: quote.map { shift($0, dx: bubble.minX, dy: bubble.minY) },
            content: shift(content, dx: bubble.minX, dy: bubble.minY),
            text: text.map { shift($0, dx: bubble.minX, dy: bubble.minY) },
            meta: meta.map { shift($0, dx: bubble.minX, dy: bubble.minY) },
            reactions: chipPlans, isFailed: m.status == .failed,
            hasTail: ctx.isLastInGroup)
    }

    // MARK: - Parts

    private static func avatarPlan(_ item: MessageItem, _ ctx: RowContext, bubble: CGRect) -> LayoutPlan.Avatar? {
        let m = item.message
        guard ctx.isGroupChat, ctx.isLastInGroup, !m.fromMe else { return nil }
        let size = M.groupAvatarSize
        return .init(frame: CGRect(x: M.horizontalInset, y: bubble.maxY - size, width: size, height: size),
                     jid: m.senderJid, initials: Initials.from(item.senderName ?? ""))
    }

    private static func placeholder(_ s: String, symbolic: Bool) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: C.bodyItalic, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: C.paragraph,
        ])
    }

    static func thumbKey(_ item: MessageItem) -> String { "thumb:\(item.message.chatJid)/\(item.id)" }
    static func fileKey(_ item: MessageItem) -> String {
        guard let media = item.media else { return "file:\(item.id)" }
        return "file:" + MediaStore.key(for: media)
    }

    private static func mediaFrameFor(_ media: MediaRecord?, maxWidth: CGFloat, contentY: CGFloat) -> (CGRect, Int) {
        let w = CGFloat(media?.width ?? 0), h = CGFloat(media?.height ?? 0)
        let aspect = (w > 0 && h > 0) ? w / h : 4.0 / 3.0
        var width = maxWidth
        var height = width / aspect
        if height > M.mediaMaxHeight {
            height = M.mediaMaxHeight
            width = height * aspect
        }
        width = max(M.mediaMinWidth, min(width, maxWidth))
        height = max(80, min(height, M.mediaMaxHeight))
        let y = contentY == M.bubblePaddingV ? M.mediaInset : contentY
        let frame = CGRect(x: M.mediaInset, y: y, width: floor(width), height: floor(height))
        return (frame, Int(max(width, height) * 2))
    }

    private static func documentPlan(_ media: MediaRecord?, frame: CGRect) -> LayoutPlan.Document {
        let name = media?.fileName ?? "Document"
        var parts: [String] = []
        if let len = media?.fileLength, len > 0 { parts.append(Int64(len).formatted(sizeFormat)) }
        if let pages = media?.pageCount, pages > 0 { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
        if let ext = name.split(separator: ".").last, name.contains(".") { parts.append(ext.uppercased()) }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingMiddle
        return .init(
            frame: frame,
            name: NSAttributedString(string: name, attributes: [.font: C.cardTitle, .foregroundColor: NSColor.labelColor, .paragraphStyle: p]),
            detail: NSAttributedString(string: parts.joined(separator: " · "), attributes: [.font: C.cardSecondary, .foregroundColor: NSColor.secondaryLabelColor]),
            fileName: name)
    }

    private static func cardPlan(_ kind: LayoutPlan.Card.Kind, frame: CGRect, title: String, subtitle: String, symbol: String) -> LayoutPlan.Card {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return .init(
            kind: kind, frame: frame,
            title: NSAttributedString(string: title, attributes: [.font: C.cardTitle, .foregroundColor: NSColor.labelColor, .paragraphStyle: p]),
            subtitle: NSAttributedString(string: subtitle, attributes: [.font: C.cardSecondary, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p]),
            symbol: symbol)
    }

    private static func pollPlan(_ item: MessageItem, _ ctx: RowContext, x: CGFloat, y: CGFloat, width: CGFloat) -> LayoutPlan.Poll {
        let poll = item.message.extra?.poll
        let question = poll?.question ?? item.message.text ?? "Poll"
        let qAttr = NSAttributedString(string: question, attributes: [.font: C.cardTitle, .foregroundColor: NSColor.labelColor, .paragraphStyle: C.paragraph])
        let qr = TextMeasurer.measure(qAttr, width: width)
        var cy = y + qr.size.height + 8
        var counts: [String: Int] = [:]
        var mine: Set<String> = []
        for v in item.pollVotes {
            for s in v.selected { counts[s, default: 0] += 1 }
            if let own = ctx.ownJid, v.voterJid == own { mine.formUnion(v.selected) }
        }
        let total = max(1, item.pollVotes.count)
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        var options: [LayoutPlan.Poll.Option] = []
        for opt in poll?.options ?? [] {
            let n = counts[opt] ?? 0
            options.append(.init(
                label: NSAttributedString(string: opt, attributes: [.font: C.card, .foregroundColor: NSColor.labelColor, .paragraphStyle: p]),
                count: NSAttributedString(string: "\(n)", attributes: [.font: C.cardSecondary, .foregroundColor: NSColor.secondaryLabelColor]),
                fraction: Double(n) / Double(total), mine: mine.contains(opt),
                frame: CGRect(x: x, y: cy, width: width, height: 24)))
            cy += 28
        }
        let votes = item.pollVotes.count
        let footer = NSAttributedString(string: votes == 1 ? "1 vote" : "\(votes) votes",
                                        attributes: [.font: C.cardSecondary, .foregroundColor: NSColor.tertiaryLabelColor])
        let footerFrame = CGRect(x: x, y: cy, width: width, height: 14)
        return .init(frame: CGRect(x: x, y: y, width: width, height: footerFrame.maxY - y),
                     question: .init(text: qAttr, frame: CGRect(x: x, y: y, width: width, height: qr.size.height)),
                     options: options, footer: .init(text: footer, frame: footerFrame))
    }

    private static func waveform(_ data: Data?) -> [Float] {
        guard let data, !data.isEmpty else {
            // Flat placeholder for plain audio files.
            return (0..<48).map { _ in 0.25 }
        }
        return data.map { Float($0) / 100 }
    }

    private static func quoteName(_ m: MessageRecord, _ ctx: RowContext) -> String {
        guard let sender = m.quotedSenderJid, !sender.isEmpty else { return "You" }
        if let own = ctx.ownJid, sender == own { return "You" }
        if !ctx.isGroupChat, let peer = ctx.peerName { return peer }
        return ctx.quotedSenderName ?? phoneDisplay(sender)
    }

    static func phoneDisplay(_ jid: String) -> String {
        let user = jid.split(separator: "@").first.map(String.init) ?? jid
        return user.allSatisfy(\.isNumber) ? "+" + user : user
    }

    private static func quoteSnippet(_ m: MessageRecord, _ snippet: String?) -> String {
        let s = snippet ?? ""
        if !s.isEmpty { return s.replacingOccurrences(of: "\n", with: " ") }
        switch m.quotedKind {
        case .image: return "Photo"
        case .video: return "Video"
        case .gif: return "GIF"
        case .sticker: return "Sticker"
        case .document: return "Document"
        case .audio: return "Audio"
        case .voice: return "Voice message"
        case .location: return "Location"
        case .contact: return "Contact"
        case .poll: return "Poll"
        default: return "Message"
        }
    }

    private static func chips(_ item: MessageItem, _ ctx: RowContext, bubble: CGRect, outgoing: Bool, bottom: inout CGFloat) -> [LayoutPlan.Chip] {
        guard !item.reactions.isEmpty, !item.message.revoked else { return [] }
        var order: [String] = []
        var counts: [String: (count: Int, mine: Bool)] = [:]
        for r in item.reactions where !r.emoji.isEmpty {
            if counts[r.emoji] == nil { order.append(r.emoji) }
            counts[r.emoji, default: (0, false)].count += 1
            if r.fromMe { counts[r.emoji]!.mine = true }
        }
        var chips: [LayoutPlan.Chip] = []
        let y = bubble.maxY - M.reactionOverlap + 2
        var widths: [CGFloat] = []
        for e in order {
            let c = counts[e]!
            let w = TextMeasurer.width(e, font: C.reaction) + (c.count > 1 ? TextMeasurer.width("\(c.count)", font: C.cardSecondary) + 4 : 0) + 14
            widths.append(w)
        }
        let total = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * M.reactionGap
        var x = outgoing ? bubble.maxX - 4 - total : bubble.minX + 4
        for (i, e) in order.enumerated() {
            let c = counts[e]!
            chips.append(.init(emoji: e, count: c.count, mine: c.mine, frame: CGRect(x: x, y: y, width: widths[i], height: M.reactionHeight)))
            x += widths[i] + M.reactionGap
        }
        bottom = y + M.reactionHeight + 2
        return chips
    }

    // MARK: - Shifting helpers

    private static func shift(_ l: LayoutPlan.Label, dx: CGFloat, dy: CGFloat) -> LayoutPlan.Label {
        .init(text: l.text, frame: l.frame.offsetBy(dx: dx, dy: dy))
    }
    private static func shift(_ q: LayoutPlan.Quote, dx: CGFloat, dy: CGFloat) -> LayoutPlan.Quote {
        .init(frame: q.frame.offsetBy(dx: dx, dy: dy), name: q.name, snippet: q.snippet, color: q.color, targetId: q.targetId)
    }
    private static func shift(_ m: LayoutPlan.Meta, dx: CGFloat, dy: CGFloat) -> LayoutPlan.Meta {
        .init(frame: m.frame.offsetBy(dx: dx, dy: dy), text: m.text, status: m.status, overlay: m.overlay)
    }
    private static func shift(_ c: LayoutPlan.Content, dx: CGFloat, dy: CGFloat) -> LayoutPlan.Content {
        switch c {
        case .none: return .none
        case .media(let m):
            return .media(.init(kind: m.kind, frame: m.frame.offsetBy(dx: dx, dy: dy), thumbKey: m.thumbKey, fileKey: m.fileKey,
                                durationText: m.durationText, pixelSize: m.pixelSize))
        case .sticker(let f, let fk, let tk, let a):
            return .sticker(frame: f.offsetBy(dx: dx, dy: dy), fileKey: fk, thumbKey: tk, animated: a)
        case .document(let d):
            return .document(.init(frame: d.frame.offsetBy(dx: dx, dy: dy), name: d.name, detail: d.detail, fileName: d.fileName))
        case .audio(let a):
            return .audio(.init(frame: a.frame.offsetBy(dx: dx, dy: dy), durationText: a.durationText, isVoice: a.isVoice, waveform: a.waveform))
        case .card(let k):
            return .card(.init(kind: k.kind, frame: k.frame.offsetBy(dx: dx, dy: dy), title: k.title, subtitle: k.subtitle, symbol: k.symbol))
        case .poll(let p):
            return .poll(.init(
                frame: p.frame.offsetBy(dx: dx, dy: dy),
                question: shift(p.question, dx: dx, dy: dy),
                options: p.options.map { .init(label: $0.label, count: $0.count, fraction: $0.fraction, mine: $0.mine, frame: $0.frame.offsetBy(dx: dx, dy: dy)) },
                footer: shift(p.footer, dx: dx, dy: dy)))
        }
    }
}
