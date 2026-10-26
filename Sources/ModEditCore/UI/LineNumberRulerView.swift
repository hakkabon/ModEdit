import AppKit

/// A lightweight line-number gutter attached to the editor's scroll view.
/// It asks TextKit for rectangles only for visible lines, so drawing cost is
/// proportional to the viewport rather than the complete document.
@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private(set) var currentLine = 1
    private(set) var displayedLineCount = 1

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
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
        guard let textView, let window = textView.window else { return }
        let gutterColor = NSColor.controlBackgroundColor.blended(
            withFraction: 0.12, of: NSColor.secondaryLabelColor) ?? .controlBackgroundColor
        gutterColor.setFill()
        bounds.fill()

        let visible = textView.visibleRect
        let text = textView.string as NSString
        let start = min(textView.characterIndexForInsertion(
            at: NSPoint(x: visible.minX, y: visible.minY)), text.length)
        let end = min(textView.characterIndexForInsertion(
            at: NSPoint(x: visible.maxX, y: visible.maxY)), text.length)
        let visibleCharacters = NSRange(location: min(start, end), length: abs(end - start))
        let visibleLines = text.lineRange(for: visibleCharacters)

        var lineNumber = 1
        var scan = 0
        while scan < visibleLines.location {
            let lineRange = text.lineRange(for: NSRange(location: scan, length: 0))
            lineNumber += 1
            let next = NSMaxRange(lineRange)
            guard next > scan else { break }
            scan = next
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        var location = visibleLines.location
        while location <= NSMaxRange(visibleLines), location <= text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            var actual = NSRange()
            let screenRect = textView.firstRect(forCharacterRange:
                NSRange(location: location, length: 0), actualRange: &actual)
            let windowRect = window.convertFromScreen(screenRect)
            let localRect = convert(windowRect, from: nil)
            let label = "\(lineNumber)" as NSString
            var lineAttributes = attributes
            if lineNumber == currentLine {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).setFill()
                NSRect(x: bounds.minX, y: localRect.minY,
                       width: bounds.width, height: screenRect.height).fill()
                lineAttributes[.foregroundColor] = NSColor.controlAccentColor
                lineAttributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            }
            let size = label.size(withAttributes: lineAttributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 9,
                                   y: localRect.minY + max(0, (screenRect.height - size.height) / 2)),
                       withAttributes: lineAttributes)

            let next = NSMaxRange(lineRange)
            guard next > location else { break }
            location = next
            lineNumber += 1
        }

        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
    }
}
