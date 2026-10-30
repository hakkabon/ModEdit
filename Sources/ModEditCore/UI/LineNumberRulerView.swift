import AppKit

/// A lightweight line-number gutter attached to the editor's scroll view.
/// It asks TextKit for rectangles only for visible lines, and it reads logical
/// line numbers from the document's shared `LineIndex` rather than keeping a
/// second index that could go stale after an edit.
@MainActor
final class LineNumberRulerView: NSRulerView {

    /// One visual fragment of a logical line. Soft wrapping produces several
    /// fragments with the same `lineNumber`; only the fragment that starts a
    /// logical line gets a number.
    struct LineFragment {
        let character: Int
        let lineNumber: Int
        let rect: NSRect
        let isLineStart: Bool
    }

    private weak var textView: NSTextView?
    private let lineSource: any LineNumberSource
    private let theme: EditorTheme
    private(set) var currentLine = 1
    private(set) var displayedLineCount = 1

    init(textView: NSTextView,
         scrollView: NSScrollView,
         lineSource: any LineNumberSource,
         theme: EditorTheme = EditorTheme()) {
        self.textView = textView
        self.lineSource = lineSource
        self.theme = theme
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

    /// Visual fragments intersecting `glyphRange`, annotated with their logical
    /// line. Internal so tests can prove that a wrapped line is numbered once.
    func lineFragments(forGlyphRange glyphRange: NSRange) -> [LineFragment] {
        guard let textView, let layoutManager = textView.layoutManager else { return [] }
        var fragments: [LineFragment] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            [lineSource] _, usedRect, _, fragmentGlyphRange, _ in
            let character = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            fragments.append(LineFragment(character: character,
                                          lineNumber: lineSource.lineNumber(at: character),
                                          rect: usedRect,
                                          isLineStart: lineSource.isLineStart(at: character)))
        }
        return fragments
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        theme.gutterBackgroundColor.setFill()
        bounds.fill()

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: theme.gutterTextColor,
        ]
        var currentAttributes = baseAttributes
        currentAttributes[.foregroundColor] = theme.gutterCurrentLineTextColor
        currentAttributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let inset = textView.textContainerInset
        let containerVisible = textView.visibleRect.offsetBy(dx: -inset.width, dy: -inset.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerVisible,
                                                  in: textContainer)

        func drawHighlight(_ fragment: NSRect) {
            let localY = convert(NSPoint(x: 0, y: fragment.minY + inset.height),
                                 from: textView).y
            theme.gutterCurrentLineColor.setFill()
            NSRect(x: bounds.minX, y: localY,
                   width: bounds.width, height: fragment.height).fill()
        }

        func drawLabel(_ lineNumber: Int, in fragment: NSRect, current: Bool) {
            let localPoint = convert(NSPoint(x: 0, y: fragment.minY + inset.height),
                                     from: textView)
            let label = "\(lineNumber)" as NSString
            let attributes = current ? currentAttributes : baseAttributes
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 9,
                                   y: localPoint.y + max(0, (fragment.height - size.height) / 2)),
                       withAttributes: attributes)
        }

        for fragment in lineFragments(forGlyphRange: glyphRange) {
            let current = fragment.lineNumber == currentLine
            if current { drawHighlight(fragment.rect) }
            // A soft-wrapped continuation fragment must not repeat the number
            // of the logical line it belongs to.
            if fragment.isLineStart {
                drawLabel(fragment.lineNumber, in: fragment.rect, current: current)
            }
        }

        // NSLayoutManager represents a real empty final row separately.
        let textLength = textView.textStorage?.length ?? 0
        if lineSource.isLineStart(at: textLength),
           layoutManager.extraLineFragmentRect.intersects(containerVisible) {
            let extra = layoutManager.extraLineFragmentRect
            let current = lineSource.lineNumber(at: textLength) == currentLine
            if current { drawHighlight(extra) }
            drawLabel(lineSource.lineNumber(at: textLength), in: extra, current: current)
        }

        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
    }
}
