import AppKit

/// Text view that paints the caret's logical line before drawing the text.
/// The highlight is visual only; it never enters `NSTextStorage`, undo history,
/// syntax attributes, or the saved document.
@MainActor
final class EditorNSTextView: NSTextView {
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let lineRect = currentLineRect(), lineRect.intersects(rect) {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.10).setFill()
            lineRect.fill()
        }
    }

    private func currentLineRect() -> NSRect? {
        guard let window else { return nil }
        let text = string as NSString
        let caret = min(selectedRange().location, text.length)
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        var actual = NSRange()
        let screenRect = firstRect(forCharacterRange:
            NSRange(location: line.location, length: 0), actualRange: &actual)
        guard !screenRect.isEmpty else { return nil }
        let localRect = convert(window.convertFromScreen(screenRect), from: nil)
        return NSRect(x: bounds.minX, y: localRect.minY,
                      width: bounds.width, height: localRect.height)
    }
}
