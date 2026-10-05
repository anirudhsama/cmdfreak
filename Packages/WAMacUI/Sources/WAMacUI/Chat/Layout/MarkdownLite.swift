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

    /// Renders with the shared body attributes; links and phone numbers get `.link`. `source` is the wire
    /// text: each "@<number>" in `mentions` is replaced by the semibold name after parsing (see `replaceMentions`).
    static func attributedString(_ source: String, mentions: [String: Mention] = [:],
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
            let tokens = mentions.isEmpty ? [] : Mentions.ranges(in: parsed.text).map(\.range)
            for match in detector.matches(in: parsed.text, range: full) {
                // Skip links inside mono spans, like the phone does, and mention numbers.
                if mask[match.range.location].contains(.mono) { continue }
                if tokens.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
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

        replaceMentions(mentions, in: result, linked: true)
        return result
    }

    /// A message's text as its previews show it (a reply's quote, the compose reply bar): rendered as
    /// the bubble renders it, on one line, at `font` in `color`, with nothing clickable.
    static func preview(_ source: String, mentions: [String: Mention], font: NSFont, color: NSColor) -> NSAttributedString {
        let s = NSMutableAttributedString(attributedString: attributedString(
            source, mentions: mentions, base: [.font: font, .foregroundColor: color], baseFont: font))
        let full = NSRange(location: 0, length: s.length)
        s.removeAttribute(.link, range: full)
        s.removeAttribute(.mention, range: full)
        s.addAttribute(.foregroundColor, value: color, range: full)
        s.enumerateAttribute(.font, in: full) { value, range, _ in
            if let f = value as? NSFont, f.isFixedPitch {
                s.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular), range: range)
            }
        }
        for r in (s.string as NSString).ranges(of: "\n").reversed() { s.replaceCharacters(in: r, with: " ") }
        return s
    }

    /// Replaces each "@<number>" in `mentions` (keyed by user number) with "@<name>" in semibold, keeping the
    /// token's other attributes. The name goes in as literal text, so formatting characters in it stay as
    /// written. `linked` also tints it and, when the mention has a JID, makes it a link carrying `.mention`
    /// (see `MessageTextView`).
    static func replaceMentions(_ mentions: [String: Mention], in s: NSMutableAttributedString, linked: Bool = false) {
        guard !mentions.isEmpty else { return }
        for token in Mentions.ranges(in: s.string).reversed() {
            guard let mention = mentions[token.user] else { continue }
            var attrs = s.attributes(at: token.range.location, effectiveRange: nil)
            if let font = attrs[.font] as? NSFont { attrs[.font] = semibold(font) }
            if linked {
                attrs[.foregroundColor] = linkColor
                if let jid = mention.jid, let url = URL(string: "cmdfreak-mention:" + jid) {
                    attrs[.link] = url
                    attrs[.mention] = mention
                }
            }
            s.replaceCharacters(in: token.range, with: NSAttributedString(string: "@" + mention.name, attributes: attrs))
        }
    }

    /// At least semibold: bold stays bold, and mono uses the monospaced system font's weight.
    private static func semibold(_ font: NSFont) -> NSFont {
        if NSFontManager.shared.weight(of: font) >= 8 { return font }
        if font.isFixedPitch { return .monospacedSystemFont(ofSize: font.pointSize, weight: .semibold) }
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

private extension NSString {
    func ranges(of needle: String) -> [NSRange] {
        var out: [NSRange] = []
        var from = 0
        while from < length {
            let r = range(of: needle, range: NSRange(location: from, length: length - from))
            guard r.location != NSNotFound else { break }
            out.append(r)
            from = r.upperBound
        }
        return out
    }
}
