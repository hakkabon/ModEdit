import Testing
import AppKit
@testable import ModEditCore

@Suite("Wrapped line rendering", .serialized)
@MainActor
struct WrappedLineRenderingTests {

    @Test func currentLineHighlightCoversEveryWrappedFragment() {
        let text = "one two three four five six seven eight nine ten\nsecond line"
        let textView = makeTextView(text: text, width: 140)
        textView.setSelectedRange(NSRange(location: 3, length: 0))

        let rects = textView.currentLineFragmentRects()

        #expect(rects.count > 1)
        #expect(Set(rects.map(\.minY)).count == rects.count)
        #expect(rects.allSatisfy { $0.width == textView.bounds.width })
    }

    @Test func caretOnTheSecondLineDoesNotHighlightTheFirstLine() throws {
        let text = "one two three four five six seven eight nine ten\nsecond line"
        let textView = makeTextView(text: text, width: 140)
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let firstLineRects = textView.currentLineFragmentRects()

        let secondLineRange = try #require(text.range(of: "second"))
        let secondLineLocation = secondLineRange.lowerBound.utf16Offset(in: text)
        textView.setSelectedRange(NSRange(location: secondLineLocation, length: 0))
        let secondLineRects = textView.currentLineFragmentRects()

        #expect(secondLineRects.count == 1)
        let firstLineMaxY = try #require(firstLineRects.map(\.maxY).max())
        #expect(secondLineRects[0].minY >= firstLineMaxY)
    }

    @Test func gutterNumbersEachLogicalLineOnceWhenWrapped() {
        let text = "one two three four five six seven eight nine ten\nsecond line"
        let textView = makeTextView(text: text, width: 140)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        let document = EditorDocument()
        document.setText(text)
        let model = EditorModel(document: document)
        let gutter = LineNumberRulerView(textView: textView,
                                         scrollView: scrollView,
                                         lineSource: model)
        let glyphCount = textView.layoutManager?.numberOfGlyphs ?? 0
        let fragments = gutter.lineFragments(
            forGlyphRange: NSRange(location: 0, length: glyphCount))

        #expect(fragments.count > model.lineCount)
        #expect(fragments.filter(\.isLineStart).count == model.lineCount)
        #expect(fragments.filter(\.isLineStart).map(\.lineNumber) == [1, 2])
        #expect(fragments.filter { !$0.isLineStart }.allSatisfy { $0.lineNumber == 1 || $0.lineNumber == 2 })
    }

    @Test func trailingNewlineHighlightsTheRealEmptyLine() {
        let textView = makeTextView(text: "first\n", width: 140)
        textView.setSelectedRange(NSRange(location: 6, length: 0))

        let rects = textView.currentLineFragmentRects()

        #expect(rects.count == 1)
        #expect(rects[0].minY >= 0)
    }

    private func makeTextView(text: String, width: CGFloat) -> EditorNSTextView {
        let textView = EditorNSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 240))
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: width - 20,
            height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return textView
    }
}
