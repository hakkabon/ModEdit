import AppKit

/// Text view that paints the caret's logical line before drawing the text.
/// The highlight is visual only; it never enters `NSTextStorage`, undo history,
/// syntax attributes, or the saved document.
@MainActor
final class EditorNSTextView: NSTextView {
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let lineRect = currentLineRect(), lineRect.intersects(rect) {
            NSColor.lightGray.withAlphaComponent(0.18).setFill()
            lineRect.fill()
        }
    }

    private func currentLineRect() -> NSRect? {
        let text = string as NSString
        let caret = min(selectedRange().location, text.length)
        let endsInNewline = text.length > 0 && [0x0A, 0x0D].contains(text.character(at: text.length - 1))
        guard let layoutManager, let textContainer else { return nil }
        let fragment: NSRect
        if caret == text.length, endsInNewline {
            layoutManager.ensureLayout(for: textContainer)
            fragment = layoutManager.extraLineFragmentRect
        } else if text.length > 0 {
            let character = caret == text.length ? caret - 1 : caret
            let glyph = layoutManager.glyphIndexForCharacter(at: character)
            fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            fragment = NSRect(x: 0, y: 0, width: bounds.width,
                              height: font?.boundingRectForFont.height ?? 16)
        }
        return NSRect(x: bounds.minX, y: fragment.minY + textContainerInset.height,
                      width: bounds.width, height: fragment.height)
    }
}
