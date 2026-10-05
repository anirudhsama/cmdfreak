import AppKit
import Testing
import WAKit
@testable import WAMacUI

@MainActor @Suite struct MentionComposeTests {
    private let alice = GroupMember(jid: "15551110000@s.whatsapp.net", name: "Alice Example", phone: "+15551110000")
    private let bob = GroupMember(jid: "99887766@lid", name: "Bob")

    /// Mentions show by name and go out as their numbers, with the JIDs they stand for.
    @Test func mentionsGoOutAsNumbers() {
        let compose = ComposeView()
        compose.mentionsEnabled = true
        compose.text = "hi @Al"
        compose.insertMention(ComposeMention(name: alice.name, user: "15551110000", jid: alice.jid))
        #expect(compose.text == "hi @Alice Example ")
        #expect(compose.composed == ComposedText(text: "hi @15551110000", mentions: [alice.jid]))
    }

    /// An edit shows the message's mentions by name and keeps the numbers they came as.
    @Test func editsRoundTripTheirMentions() {
        let compose = ComposeView()
        let mentions = ["99887766": Mention(name: "Alice Example", jid: alice.jid, phone: nil)]
        compose.draft = ComposeView.editable("@99887766 ok @12345678", mentions: mentions)
        #expect(compose.text == "@Alice Example ok @12345678")
        #expect(compose.composed.text == "@99887766 ok @12345678")
    }

    /// Typing inside a mention makes it plain text in one change, so undo restores the mention.
    @Test func undoRestoresAMentionTypedInto() throws {
        let compose = ComposeView()
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.contentView = compose
        let undo = try #require(compose.textView.undoManager)
        undo.groupsByEvent = false
        compose.mentionsEnabled = true
        compose.text = "@Al"
        undo.beginUndoGrouping()
        compose.insertMention(ComposeMention(name: alice.name, user: "15551110000", jid: alice.jid))
        undo.endUndoGrouping()

        undo.beginUndoGrouping()
        compose.textView.insertText("x", replacementRange: NSRange(location: 3, length: 0))
        undo.endUndoGrouping()
        #expect(compose.text == "@Alxice Example ")
        #expect(compose.composed == ComposedText(text: "@Alxice Example"))

        undo.undo()
        #expect(compose.text == "@Alice Example ")
        #expect(compose.composed == ComposedText(text: "@15551110000", mentions: [alice.jid]))
    }

    /// Esc closes the picker before it cancels a reply; the closed "@" stays closed only in its draft.
    @Test func escClosesThePickerFirst() {
        let compose = ComposeView()
        var query: String?
        compose.onMentionQuery = { query = $0 }
        compose.onMentionKey = { _ in query != nil }
        compose.mentionsEnabled = true
        compose.setBar(.reply(name: "Bob", snippet: NSAttributedString(string: "hi"), color: .systemGreen))
        compose.text = "@Al"
        #expect(query == "Al")

        #expect(compose.handleEscape())
        #expect(query == nil)
        #expect(compose.bar != nil)

        compose.draft = NSAttributedString(string: "@Bo")
        #expect(query == "Bo")
    }

    /// The reply's close button cancels the reply even with the picker open.
    @Test func closeButtonCancelsTheReply() {
        let compose = ComposeView()
        var query: String?
        compose.onMentionQuery = { query = $0 }
        compose.onMentionKey = { _ in query != nil }
        compose.mentionsEnabled = true
        compose.setBar(.reply(name: "Bob", snippet: NSAttributedString(string: "hi"), color: .systemGreen))
        compose.text = "@Al"
        compose.perform(Selector(("cancelBar")))
        #expect(compose.bar == nil)
    }

    /// An input method composing inside a mention turns it plain without committing its first update.
    @Test func markedTextInsideAMentionComposes() {
        let compose = ComposeView()
        compose.mentionsEnabled = true
        compose.text = "@Al"
        compose.insertMention(ComposeMention(name: alice.name, user: "15551110000", jid: alice.jid))
        let view = compose.textView
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        #expect(compose.text == "@Al日本ice Example ")
        #expect(compose.composed == ComposedText(text: "@Al日本ice Example"))
    }

    /// Composition at a range the input method names, away from the caret inside a mention, leaves it alone.
    @Test func markedTextElsewhereKeepsTheMention() {
        let compose = ComposeView()
        compose.mentionsEnabled = true
        compose.text = "@Al"
        compose.insertMention(ComposeMention(name: alice.name, user: "15551110000", jid: alice.jid))
        let view = compose.textView
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(compose.text == "日本@Alice Example ")
        #expect(compose.composed == ComposedText(text: "日本@15551110000", mentions: [alice.jid]))
    }

    @Test func pickerMatchesNamesAndNumbers() {
        let model = MentionPickerModel()
        model.members = [alice, bob]
        model.query = ""
        #expect(model.results == [alice, bob])
        model.query = "bo"
        #expect(model.results == [bob])
        model.query = "ae"  // initials
        #expect(model.results == [alice])
        model.query = "555111"
        #expect(model.results == [alice])
        model.query = "lxe"  // subsequence only
        #expect(model.results.isEmpty)
        model.query = nil
        #expect(!model.isShowing)
    }
}
