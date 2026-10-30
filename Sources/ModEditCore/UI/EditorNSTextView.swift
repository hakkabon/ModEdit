import AppKit

/// Text view that paints the caret's logical line before drawing the text.
/// The highlight is visual only; it never enters `NSTextStorage`, undo history,
/// syntax attributes, or the saved document.
@MainActor
final class EditorNSTextView: NSTextView {
    /// Usually supplied by `EditorTheme`; dynamic so light/dark mode is handled
    /// by AppKit when the view redraws.
    var currentLineColor: NSColor = .lightGray.withAlphaComponent(0.18) {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        currentLineColor.setFill()
        for lineRect in currentLineFragmentRects() where lineRect.intersects(rect) {
            lineRect.fill()
        }
    }

    /// Rectangles for every visual fragment of the logical line containing the
    /// caret. A soft-wrapped line spans several layout fragments, and all of
    /// them belong to the highlighted line.
    func currentLineFragmentRects() -> [NSRect] {
        guard let layoutManager, let textContainer else { return [] }
        let text = textStorage?.mutableString ?? (string as NSString)
        let length = text.length
        let caret = min(max(selectedRange().location, 0), length)

        if length == 0 {
            let height = font?.boundingRectForFont.height ?? 16
            return [insetRect(NSRect(x: 0, y: 0, width: bounds.width, height: height))]
        }

        // A trailing newline creates a real empty final line that TextKit
        // represents with `extraLineFragmentRect` rather than a glyph fragment.
        if caret == length, isLineBreak(text.character(at: length - 1)) {
            layoutManager.ensureLayout(for: textContainer)
            return [insetRect(layoutManager.extraLineFragmentRect)]
        }

        let character = caret == length ? caret - 1 : caret
        let lineRange = text.lineRange(for: NSRange(location: character, length: 0))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange,
                                                  actualCharacterRange: nil)
        var rects: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            [weak self] fragment, _, _, _, _ in
            guard let self else { return }
            rects.append(self.insetRect(fragment))
        }

        if rects.isEmpty, length > 0 {
            let glyph = layoutManager.glyphIndexForCharacter(at: character)
            rects.append(insetRect(layoutManager.lineFragmentRect(forGlyphAt: glyph,
                                                                  effectiveRange: nil)))
        }
        return rects
    }

    private func insetRect(_ fragment: NSRect) -> NSRect {
        NSRect(x: bounds.minX,
               y: fragment.minY + textContainerInset.height,
               width: bounds.width,
               height: fragment.height)
    }

    private func isLineBreak(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D
    }
}
