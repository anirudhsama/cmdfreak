import AppKit
import Foundation
import WAKit

/// WhatsApp's inline formatting: `*bold*`, `_italic_`, `~strike~`, `` `mono` `` and ``` ```mono``` ```.
/// Markers must hug their content (`* bold*` is literal) and cannot span lines, matching the phone.
enum MarkdownLite {
    struct Span: Equatable, Sendable {
        var range: Range<Int>  // UTF-16 offsets in the rendered string
        var style: Style
    }

    struct Style: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let bold = Style(rawValue: 1)
        static let italic = Style(rawValue: 2)
        static let strike = Style(rawValue: 4)
        static let mono = Style(rawValue: 8)
    }

    struct Parsed: Equatable, Sendable {
        var text: String
        var spans: [Span]
    }

    private static let markers: [(Character, Style)] = [("*", .bold), ("_", .italic), ("~", .strike)]

    static func parse(_ source: String) -> Parsed {
        var out = ""
        out.reserveCapacity(source.utf16.count)
        var spans: [Span] = []
        var outLen = 0  // UTF-16 length of `out`

        let chars = Array(source)
        var i = 0
        // Open marker → start offset in `out`.
        var open: [Style: Int] = [:]
        var activeStyles: Style = []

        func append(_ c: Character) {
            out.append(c)
            outLen += c.utf16.count
        }
        func appendText(_ s: Substring) {
            out.append(contentsOf: s)
            outLen += s.utf16.count
        }
        func closeAll(at offset: Int) {
            // Line breaks end every open marker; the marker chars stay literal.
            for (style, start) in open {
                if outLen > start { spans.append(Span(range: start..<offset, style: style)) }
            }
            open.removeAll()
            activeStyles = []
        }

        while i < chars.count {
            let c = chars[i]

            // Fenced mono ``` ... ```
            if c == "`", i + 2 < chars.count, chars[i + 1] == "`", chars[i + 2] == "`" {
                if let end = findFence(chars, from: i + 3) {
                    let start = outLen
                    appendText(Substring(chars[(i + 3)..<end]))
                    if outLen > start { spans.append(Span(range: start..<outLen, style: .mono)) }
                    i = end + 3
                    continue
                }
            }
            // Inline mono ` ... ` (single line)
            if c == "`" {
                if let end = chars[(i + 1)...].firstIndex(where: { $0 == "`" || $0 == "\n" }), chars[end] == "`", end > i + 1 {
                    let start = outLen
                    appendText(Substring(chars[(i + 1)..<end]))
                    spans.append(Span(range: start..<outLen, style: .mono))
                    i = end + 1
                    continue
                }
            }
            if c == "\n" {
                append(c)
                closeAll(at: outLen)
                i += 1
                continue
            }
            if let (_, style) = markers.first(where: { $0.0 == c }) {
                if let start = open[style] {
                    // Closing: previous char must not be whitespace and there must be content.
                    let prev = i > 0 ? chars[i - 1] : " "
                    if !prev.isWhitespace, outLen > start {
                        spans.append(Span(range: start..<outLen, style: style))
                        open[style] = nil
                        activeStyles.remove(style)
                        i += 1
                        continue
                    }
                } else {
                    // Opening: next char must not be whitespace, previous must not be alphanumeric,
                    // and a closer must exist on this line.
                    let next = i + 1 < chars.count ? chars[i + 1] : " "
                    let prev = i > 0 ? chars[i - 1] : " "
                    if !next.isWhitespace, next != c, !prev.isLetter, !prev.isNumber, hasCloser(chars, from: i + 1, marker: c) {
                        open[style] = outLen
                        activeStyles.insert(style)
                        i += 1
                        continue
                    }
                }
            }
            append(c)
            i += 1
        }
        closeAll(at: outLen)
        // Unclosed markers were consumed as openers only when a closer existed, so nothing to restore.
        return Parsed(text: out, spans: spans.sorted { $0.range.lowerBound < $1.range.lowerBound })
    }

    private static func findFence(_ chars: [Character], from: Int) -> Int? {
        var j = from
        while j + 2 < chars.count {
            if chars[j] == "`", chars[j + 1] == "`", chars[j + 2] == "`" { return j > from ? j : nil }
            j += 1
        }
        return nil
    }

    private static func hasCloser(_ chars: [Character], from: Int, marker: Character) -> Bool {
        var j = from
        while j < chars.count {
            let c = chars[j]
            if c == "\n" { return false }
            if c == marker, j > from, !chars[j - 1].isWhitespace { return true }
            j += 1
        }
        return false
    }

    // MARK: Attributed rendering

    /// Messages' link blue; `NSColor.linkColor` is darker and reads as muted in a bubble.
    static let linkColor = NSColor.systemBlue

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue
        | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    /// Renders with the shared body attributes; links and phone numbers get `.link`, and "@<name>" for each
    /// of `mentions` is semibold in the link colour, and clickable when it has a JID.
    static func attributedString(_ source: String, mentions: some Collection<Mention> = [Mention](),
                                 base: [NSAttributedString.Key: Any] = MessageTextConfiguration.bodyAttributes,
                                 baseFont: NSFont = MessageTextConfiguration.body) -> NSAttributedString {
        let parsed = parse(source)
        let result = NSMutableAttributedString(string: parsed.text, attributes: base)
        let full = NSRange(location: 0, length: result.length)

        // Merge overlapping spans into per-character style masks.
        var mask = [Style](repeating: [], count: result.length)
        for span in parsed.spans {
            for k in span.range where k < mask.count { mask[k].insert(span.style) }
        }
        var k = 0
        while k < mask.count {
            let style = mask[k]
            var end = k
            while end < mask.count, mask[end] == style { end += 1 }
            if !style.isEmpty {
                result.addAttributes(attributes(for: style, baseFont: baseFont), range: NSRange(location: k, length: end - k))
            }
            k = end
        }

        if let detector {
            for match in detector.matches(in: parsed.text, range: full) {
                // Skip links inside mono spans, like the phone does.
                if mask[match.range.location].contains(.mono) { continue }
                let url: URL?
                switch match.resultType {
                case .link: url = match.url
                case .phoneNumber: url = match.phoneNumber.flatMap { URL(string: "tel:" + $0.filter { !$0.isWhitespace }) }
                default: url = nil
                }
                if let url {
                    result.addAttributes([.link: url, .foregroundColor: linkColor], range: match.range)
                }
            }
        }

        emphasizeMentions(mentions, in: result, linked: true)
        return result
    }

    /// Sets each "@<name>" for `mentions` in semibold, keeping any italic or mono. `linked` also tints it
    /// and, when the mention has a JID, makes it a link carrying `.mention` (see `MessageTextView`).
    static func emphasizeMentions(_ mentions: some Collection<Mention>, in s: NSMutableAttributedString, linked: Bool = false) {
        let text = s.string as NSString
        var seen: Set<String> = []
        for mention in mentions where seen.insert(mention.name).inserted {
            let token = "@" + mention.name
            var r = text.range(of: token)
            while r.location != NSNotFound {
                s.enumerateAttribute(.font, in: r) { font, sub, _ in
                    if let font = font as? NSFont { s.addAttribute(.font, value: semibold(font), range: sub) }
                }
                if linked {
                    s.addAttribute(.foregroundColor, value: linkColor, range: r)
                    if let jid = mention.jid, let url = URL(string: "cmdfreak-mention:" + jid) {
                        s.addAttributes([.link: url, .mention: mention], range: r)
                    }
                }
                r = text.range(of: token, range: NSRange(location: NSMaxRange(r), length: text.length - NSMaxRange(r)))
            }
        }
    }

    private static func semibold(_ font: NSFont) -> NSFont {
        var traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any] ?? [:]
        traits[.weight] = NSFont.Weight.semibold
        return NSFont(descriptor: font.fontDescriptor.addingAttributes([.traits: traits]), size: font.pointSize) ?? font
    }

    private static func attributes(for style: Style, baseFont: NSFont) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [:]
        if style.contains(.mono) {
            attrs[.font] = MessageTextConfiguration.mono
        } else {
            var traits: NSFontTraitMask = []
            if style.contains(.bold) { traits.insert(.boldFontMask) }
            if style.contains(.italic) { traits.insert(.italicFontMask) }
            if !traits.isEmpty { attrs[.font] = NSFontManager.shared.convert(baseFont, toHaveTrait: traits) }
        }
        if style.contains(.strike) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    /// True when the text is 1–3 emoji and nothing else (rendered large, no bubble padding change).
    static func isEmojiOnly(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { !$0.properties.isVariationSelector && $0.value != 0x200D }
        guard !scalars.isEmpty, scalars.count <= 8 else { return false }
        var count = 0
        for c in text where !c.isWhitespace {
            guard c.unicodeScalars.first?.properties.isEmojiPresentation == true
                || (c.unicodeScalars.count > 1 && c.unicodeScalars.contains { $0.properties.isEmoji }) else { return false }
            count += 1
        }
        return count > 0 && count <= 3
    }
}

extension NSAttributedString.Key {
    /// The `Mention` behind a clickable "@<name>".
    static let mention = NSAttributedString.Key("CmdFreakMention")
}
