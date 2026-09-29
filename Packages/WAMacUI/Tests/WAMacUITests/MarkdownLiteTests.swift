import AppKit
import Testing
import WAKit
@testable import WAMacUI

@Suite struct MarkdownLiteTests {
    @Test func boldItalicStrikeMono() {
        let p = MarkdownLite.parse("*bold* _it_ ~gone~ `code`")
        #expect(p.text == "bold it gone code")
        #expect(p.spans.map(\.style) == [.bold, .italic, .strike, .mono])
        #expect(p.spans[0].range == 0..<4)
        #expect(p.spans[3].range == 13..<17)
    }

    @Test func markersMustHugContent() {
        #expect(MarkdownLite.parse("* not bold*").text == "* not bold*")
        #expect(MarkdownLite.parse("2*3*4").text == "2*3*4")
        #expect(MarkdownLite.parse("a_b_c").text == "a_b_c")
        #expect(MarkdownLite.parse("*unclosed").text == "*unclosed")
    }

    @Test func markersDoNotCrossLines() {
        let p = MarkdownLite.parse("*line one\nline two*")
        #expect(p.text == "*line one\nline two*")
        #expect(p.spans.isEmpty)
    }

    @Test func fencedMono() {
        let p = MarkdownLite.parse("```let x = 1\nlet y = 2```")
        #expect(p.text == "let x = 1\nlet y = 2")
        #expect(p.spans == [.init(range: 0..<19, style: .mono)])
    }

    @Test func nestedStyles() {
        let p = MarkdownLite.parse("*_both_*")
        #expect(p.text == "both")
        #expect(Set(p.spans.map(\.style)) == [.bold, .italic])
    }

    @Test func linksAndPhones() {
        let a = MarkdownLite.attributedString("see https://example.com or call +1 555 010 9999")
        var links: [URL] = []
        a.enumerateAttribute(.link, in: NSRange(location: 0, length: a.length)) { v, _, _ in
            if let u = v as? URL { links.append(u) }
        }
        #expect(links.contains { $0.absoluteString == "https://example.com" })
        #expect(links.contains { $0.scheme == "tel" })
    }

    @Test func mentionsStyledAndLinked() {
        let mentions = [Mention(name: "Bob", jid: "15552220000@s.whatsapp.net", phone: "+15552220000"),
                        Mention(name: "Alice", jid: nil, phone: nil)]
        let a = MarkdownLite.attributedString("*@Alice* hi @Bob and @Bob", mentions: mentions)
        var tinted: [String] = []
        a.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: a.length)) { v, r, _ in
            if (v as? NSColor) == MarkdownLite.linkColor { tinted.append((a.string as NSString).substring(with: r)) }
        }
        #expect(tinted == ["@Alice", "@Bob", "@Bob"])
        let bob = a.attribute(.font, at: (a.string as NSString).range(of: "@Bob").location, effectiveRange: nil) as! NSFont
        let hi = a.attribute(.font, at: (a.string as NSString).range(of: "hi").location, effectiveRange: nil) as! NSFont
        #expect(NSFontManager.shared.weight(of: bob) > NSFontManager.shared.weight(of: hi))
        var linked: [String] = []
        a.enumerateAttribute(.mention, in: NSRange(location: 0, length: a.length)) { v, r, _ in
            if (v as? Mention)?.name == "Bob" { linked.append((a.string as NSString).substring(with: r)) }
        }
        #expect(linked == ["@Bob", "@Bob"])
        #expect(a.attribute(.link, at: 1, effectiveRange: nil) == nil)
    }

    @Test func emojiOnly() {
        #expect(MarkdownLite.isEmojiOnly("👍"))
        #expect(MarkdownLite.isEmojiOnly("😂😂🔥"))
        #expect(!MarkdownLite.isEmojiOnly("ok 👍"))
        #expect(!MarkdownLite.isEmojiOnly("😀😀😀😀"))
    }
}
