import AppKit

/// A lightweight line-number gutter attached to the editor's scroll view.
/// It asks TextKit for rectangles only for visible lines, so drawing cost is
/// proportional to the viewport rather than the complete document.
@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private(set) var currentLine = 1
    private(set) var displayedLineCount = 1
    private var lineIndex: LineIndex

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.lineIndex = LineIndex(text: textView.string)
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsDidChange),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func boundsDidChange() { needsDisplay = true }

    func updateLineCount(_ lineCount: Int) {
        let changed = displayedLineCount != max(1, lineCount)
        displayedLineCount = max(1, lineCount)
        if changed, let textView { lineIndex.rebuild(from: textView.string) }
        let digits = String(displayedLineCount).count
        let width = max(44, CGFloat(digits * 8 + 18))
        if width != ruleThickness { ruleThickness = width }
        // The width commonly stays unchanged when a line is inserted. We must
        // still repaint so the newly created line number becomes visible.
        needsDisplay = true
    }

    func updateCurrentLine(_ line: Int) {
        currentLine = max(1, line)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let gutterColor = NSColor.controlBackgroundColor.blended(
            withFraction: 0.12, of: NSColor.secondaryLabelColor) ?? .controlBackgroundColor
        gutterColor.setFill()
        bounds.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let inset = textView.textContainerInset
        let containerVisible = textView.visibleRect.offsetBy(dx: -inset.width, dy: -inset.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerVisible, in: textContainer)

        func drawLabel(lineNumber: Int, fragment: NSRect) {
            let localPoint = convert(NSPoint(x: 0, y: fragment.minY + inset.height), from: textView)
            let label = "\(lineNumber)" as NSString
            var lineAttributes = attributes
            if lineNumber == currentLine {
                NSColor.lightGray.withAlphaComponent(0.22).setFill()
                NSRect(x: bounds.minX, y: localPoint.y,
                       width: bounds.width, height: fragment.height).fill()
                lineAttributes[.foregroundColor] = NSColor.controlAccentColor
                lineAttributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            }
            let size = label.size(withAttributes: lineAttributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 9,
                                   y: localPoint.y + max(0, (fragment.height - size.height) / 2)),
                       withAttributes: lineAttributes)
        }

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            [lineIndex] _, usedRect, _, fragmentGlyphRange, _ in
            let character = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            drawLabel(lineNumber: lineIndex.lineAndColumn(at: character).line,
                      fragment: usedRect)
        }

        // NSLayoutManager represents a real empty final row separately.
        if lineIndex.starts.last == textView.string.utf16.count,
           layoutManager.extraLineFragmentRect.intersects(containerVisible) {
            drawLabel(lineNumber: lineIndex.starts.count,
                      fragment: layoutManager.extraLineFragmentRect)
        }

        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
    }

    /// `text.length` is a real line start only for an empty document or when a
    /// newline terminates the preceding line. This prevents drawing a synthetic
    /// n+1 row for ordinary files with no trailing newline.
    static func lineStarts(at location: Int, in text: NSString) -> Bool {
        guard location >= 0, location <= text.length else { return false }
        if location == 0 { return true }
        if location < text.length { return true }
        return [0x0A, 0x0D].contains(text.character(at: text.length - 1))
    }
}
