import AppKit

/// A lightweight line-number gutter attached to the editor's scroll view.
/// It asks TextKit for rectangles only for visible lines, and it reads logical
/// line numbers from the document's shared `LineIndex` rather than keeping a
/// second index that could go stale after an edit.
@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private let lineSource: any LineNumberSource
    private(set) var currentLine = 1
    private(set) var displayedLineCount = 1

    init(textView: NSTextView,
         scrollView: NSScrollView,
         lineSource: any LineNumberSource) {
        self.textView = textView
        self.lineSource = lineSource
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        displayedLineCount = max(1, lineSource.lineCount)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsDidChange),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func boundsDidChange() { needsDisplay = true }

    /// Reads the current count from the shared line source.
    func refreshLineCount() {
        updateLineCount(lineSource.lineCount)
    }

    func updateLineCount(_ lineCount: Int) {
        displayedLineCount = max(1, lineCount)
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
            [lineSource] _, usedRect, _, fragmentGlyphRange, _ in
            let character = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            drawLabel(lineNumber: lineSource.lineNumber(at: character),
                      fragment: usedRect)
        }

        // NSLayoutManager represents a real empty final row separately.
        let textLength = textView.textStorage?.length ?? 0
        if lineSource.isLineStart(at: textLength),
           layoutManager.extraLineFragmentRect.intersects(containerVisible) {
            drawLabel(lineNumber: lineSource.lineNumber(at: textLength),
                      fragment: layoutManager.extraLineFragmentRect)
        }

        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
    }
}
