import Testing
import WAKit
@testable import WAMacUI

@Suite struct NotificationBodyTests {
    @Test func captionOrLabelBehindEmoji() {
        #expect(NotificationController.body(kind: .text, text: "  hi \n") == "hi")
        #expect(NotificationController.body(kind: .image, text: nil) == "📷 Photo")
        #expect(NotificationController.body(kind: .image, text: "Look") == "📷 Look")
        #expect(NotificationController.body(kind: .voice, text: "") == "🎤 Voice message")
        #expect(NotificationController.body(kind: .sticker, text: nil) == "Sticker")
    }
}
