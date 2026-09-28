import AppKit

extension NSEvent {
    /// The text a key press would type, or nil for shortcuts, control characters, and arrow and
    /// function keys (whose characters sit in the U+F700 private-use range).
    var typedText: String? {
        guard modifierFlags.isDisjoint(with: [.command, .control, .function]),
              let text = characters, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
        else { return nil }
        return text
    }
}
