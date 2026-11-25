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

    /// A standalone Markdown image drawn over its source line.
    struct RenderedImageAttachment {
        let sourceRange: Range<Int>
        let lineRange: Range<Int>
        let image: NSImage
        /// The scaled size actually painted, also used to reserve line height.
        let displaySize: NSSize
    }

    /// Images to paint after AppKit has drawn the text. The source characters
    /// stay in storage; the coordinator clears their colour and reserves line
    /// height, so the image is a presentation attachment rather than a second
    /// text buffer.
    var renderedImages: [RenderedImageAttachment] = [] {
        didSet { needsDisplay = true }
    }

    var renderedImageBackgroundColor: NSColor = .textBackgroundColor {
        didSet { needsDisplay = true }
    }

    static let maximumImageHeight: CGFloat = 320
    static let imageVerticalPadding: CGFloat = 8
    private static let imageHorizontalInset: CGFloat = 4

    /// The reserved line height for an image, including padding.
    static func reservedImageHeight(for displaySize: NSSize) -> CGFloat {
        min(max(0, displaySize.height), maximumImageHeight) + imageVerticalPadding
    }

    /// Scales an image to the available width and the maximum height without
    /// enlarging small images.
    static func displaySize(for imageSize: NSSize,
                            availableWidth: CGFloat) -> NSSize {
        guard imageSize.width > 0, imageSize.height > 0,
              availableWidth > 0 else { return .zero }
        let scale = min(1, min(availableWidth / imageSize.width,
                               maximumImageHeight / imageSize.height))
        return NSSize(width: imageSize.width * scale,
                      height: imageSize.height * scale)
    }

    /// Handles horizontal caret movement through the rendered projection.
    ///
    /// Returns `true` when the projection consumed the move. The coordinator
    /// only installs this while rendered editing is active; plain source mode
    /// keeps AppKit's native movement.
    var renderedNavigation: ((_ direction: Int, _ extending: Bool) -> Bool)?

    override func moveLeft(_ sender: Any?) {
        moveThroughRenderedText(direction: -1, extending: false, sender: sender)
    }

    override func moveRight(_ sender: Any?) {
        moveThroughRenderedText(direction: 1, extending: false, sender: sender)
    }

    override func moveLeftAndModifySelection(_ sender: Any?) {
        moveThroughRenderedText(direction: -1, extending: true, sender: sender)
    }

    override func moveRightAndModifySelection(_ sender: Any?) {
        moveThroughRenderedText(direction: 1, extending: true, sender: sender)
    }

    private func moveThroughRenderedText(direction: Int,
                                         extending: Bool,
                                         sender: Any?) {
        if renderedNavigation?(direction, extending) == true { return }
        switch (direction, extending) {
        case (-1, false): super.moveLeft(sender)
        case (1, false): super.moveRight(sender)
        case (-1, true): super.moveLeftAndModifySelection(sender)
        case (1, true): super.moveRightAndModifySelection(sender)
        default: break
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        currentLineColor.setFill()
        for lineRect in currentLineFragmentRects() where lineRect.intersects(rect) {
            lineRect.fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawRenderedImages(intersecting: dirtyRect)
    }

    private func drawRenderedImages(intersecting dirtyRect: NSRect) {
        guard !renderedImages.isEmpty,
              let layoutManager else { return }
        let length = textStorage?.length ?? 0

        for attachment in renderedImages {
            guard attachment.lineRange.lowerBound < length else { continue }
            let characterRange = NSRange(
                location: attachment.lineRange.lowerBound,
                length: min(attachment.lineRange.count, length - attachment.lineRange.lowerBound))
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location, effectiveRange: nil)
            let lineRect = NSRect(
                x: 0,
                y: fragment.minY + textContainerInset.height,
                width: bounds.width,
                height: max(fragment.height,
                            Self.reservedImageHeight(for: attachment.displaySize)))
            guard lineRect.intersects(dirtyRect) else { continue }

            let originX = textContainerInset.width + Self.imageHorizontalInset
                + layoutManager.location(forGlyphAt: glyphRange.location).x
            let displaySize = attachment.displaySize
            guard displaySize.width > 0, displaySize.height > 0 else { continue }

            // Cover the (invisible) source glyphs before compositing the image.
            renderedImageBackgroundColor.setFill()
            lineRect.fill()
            attachment.image.draw(
                in: NSRect(x: originX,
                           y: lineRect.minY + Self.imageVerticalPadding / 2,
                           width: displaySize.width,
                           height: displaySize.height),
                from: .zero, operation: .sourceOver, fraction: 1)
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
