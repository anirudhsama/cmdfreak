import AppKit
import CoreText

/// Core Text measurement. `MessageTextView` renders the same attributed string with a zero
/// line-fragment padding container, so these sizes are the rendered sizes.
enum TextMeasurer {
    struct Result: Equatable, Sendable {
        var size: CGSize
        var lastLineWidth: CGFloat
        var lineCount: Int
    }

    static func measure(_ text: NSAttributedString, width: CGFloat) -> Result {
        guard text.length > 0 else { return Result(size: .zero, lastLineWidth: 0, lineCount: 0) }
        let constraint = CGSize(width: max(1, floor(width)), height: .greatestFiniteMagnitude)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let range = CFRange(location: 0, length: text.length)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, range, nil, constraint, nil)
        let size = CGSize(width: ceil(suggested.width), height: ceil(suggested.height))

        // Last line width decides whether the time label can share the final line.
        let path = CGPath(rect: CGRect(origin: .zero, size: CGSize(width: constraint.width, height: max(size.height, 1) + 2)), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var last: CGFloat = 0
        if let line = lines.last {
            last = ceil(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
        }
        return Result(size: size, lastLineWidth: last, lineCount: lines.count)
    }

    /// Single-line width for short labels (times, names, chips).
    static func width(_ text: String, font: NSFont) -> CGFloat {
        let s = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(s)
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
