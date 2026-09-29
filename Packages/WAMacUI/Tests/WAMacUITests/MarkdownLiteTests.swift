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
        let mentions = ["15552220000": Mention(name: "Bob", jid: "15552220000@s.whatsapp.net", phone: "+15552220000"),
                        "11112222": Mention(name: "You", jid: nil, phone: nil)]
        let a = MarkdownLite.attributedString("*@11112222* hi @15552220000 and @15552220000", mentions: mentions)
        let text = a.string as NSString
        #expect(a.string == "@You hi @Bob and @Bob")
        #expect(runs(of: .foregroundColor, in: a) { ($0 as? NSColor) == MarkdownLite.linkColor } == ["@You", "@Bob", "@Bob"])
        #expect(runs(of: .mention, in: a) { ($0 as? Mention)?.name == "Bob" } == ["@Bob", "@Bob"])
        #expect(a.attribute(.link, at: 1, effectiveRange: nil) == nil)
        let weight = { (i: Int) in NSFontManager.shared.weight(of: a.attribute(.font, at: i, effectiveRange: nil) as! NSFont) }
        #expect(weight(text.range(of: "@Bob").location) > weight(text.range(of: "hi").location))
        #expect(weight(0) >= 9)  // bold stays bold
    }

    /// Mentions are placed by their number, so equal or prefixed names, formatting characters in a name and
    /// literal "@Name" text cannot pick up the wrong person.
    @Test func mentionsKeepTheirIdentity() {
        let mentions = ["15550000001": Mention(name: "Sam", jid: "15550000001@s.whatsapp.net", phone: nil),
                        "15550000002": Mention(name: "Sam", jid: "15550000002@s.whatsapp.net", phone: nil),
                        "15550000003": Mention(name: "Ann", jid: "15550000003@s.whatsapp.net", phone: nil),
                        "15550000004": Mention(name: "_Anna_", jid: "15550000004@s.whatsapp.net", phone: nil)]
        let a = MarkdownLite.attributedString("@15550000001 @15550000002 @15550000004 @15550000003 mail @Sam", mentions: mentions)
        #expect(a.string == "@Sam @Sam @_Anna_ @Ann mail @Sam")
        #expect(runs(of: .mention, in: a) { $0 != nil }.count == 4)
        var jids: [String] = []
        a.enumerateAttribute(.mention, in: NSRange(location: 0, length: a.length)) { v, _, _ in
            if let jid = (v as? Mention)?.jid { jids.append(String(jid.prefix(11))) }
        }
        #expect(jids == ["15550000001", "15550000002", "15550000004", "15550000003"])
    }

    private func runs(of key: NSAttributedString.Key, in a: NSAttributedString, where match: (Any?) -> Bool) -> [String] {
        var out: [String] = []
        a.enumerateAttribute(key, in: NSRange(location: 0, length: a.length)) { v, r, _ in
            if match(v) { out.append((a.string as NSString).substring(with: r)) }
        }
        return out
    }

    @Test func emojiOnly() {
        #expect(MarkdownLite.isEmojiOnly("👍"))
        #expect(MarkdownLite.isEmojiOnly("😂😂🔥"))
        #expect(!MarkdownLite.isEmojiOnly("ok 👍"))
        #expect(!MarkdownLite.isEmojiOnly("😀😀😀😀"))
    }
}
