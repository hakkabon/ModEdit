import Testing
import AppKit
@testable import ModEditCore

@Suite("Preview scroll synchronisation", .serialized)
@MainActor
struct PreviewScrollSynchronisationTests {

    @Test func caretLineChangesRequestPreviewScrolling() throws {
        let harness = makeHarness(text: "one\ntwo\nthree\n")

        harness.textView.setSelectedRange(NSRange(location: 5, length: 0))

        let request = try #require(harness.model.previewScrollRequest)
        #expect(request.line == 2)

        // Moving inside the same line must not recentre the preview.
        harness.textView.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(harness.model.previewScrollRequest?.id == request.id)

        harness.textView.setSelectedRange(NSRange(location: 9, length: 0))
        #expect(harness.model.previewScrollRequest?.line == 3)
        #expect(harness.model.previewScrollRequest?.id != request.id)
    }

    @Test func previewRequestsClampToTheDocument() throws {
        let harness = makeHarness(text: "one\ntwo")

        harness.model.requestPreviewScroll(toLine: 99)
        #expect(harness.model.previewScrollRequest?.line == 2)

        harness.model.scrollEditor(toPreviewLine: 0)
        #expect(harness.model.editorScrollRequest?.line == 1)

        harness.model.scrollEditor(toPreviewLine: 99)
        let request = try #require(harness.model.editorScrollRequest)
        #expect(request.line == 2)
    }

    @Test func acknowledgingAScrollRequestOnlyClearsTheMatchingRequest() {
        let harness = makeHarness(text: "one\ntwo\n")

        harness.model.scrollEditor(toPreviewLine: 2)
        let request = harness.model.editorScrollRequest
        harness.model.acknowledgeEditorScrollRequest(id: (request?.id ?? 0) + 1)
        #expect(harness.model.editorScrollRequest == request)

        harness.model.acknowledgeEditorScrollRequest(id: request?.id ?? 0)
        #expect(harness.model.editorScrollRequest == nil)
    }

    @Test func lineStartsHandleUnixWindowsAndClassicLineEndings() {
        let document = EditorDocument()
        document.setText("aa\r\nbb\rcc")

        #expect(document.lineStart(atLine: 1) == 0)
        #expect(document.lineStart(atLine: 2) == 4)
        #expect(document.lineStart(atLine: 3) == 7)
        // Out-of-range lines clamp instead of trapping.
        #expect(document.lineStart(atLine: 0) == 0)
        #expect(document.lineStart(atLine: 99) == 7)
    }

    @Test func previewScrollRevealsTheLineWithoutMovingTheCaret() throws {
        let text = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let harness = makeHarness(text: text, height: 120)
        harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let scrollView = try #require(harness.textView.enclosingScrollView)
        let originalCaret = harness.textView.selectedRange()

        harness.model.scrollEditor(toPreviewLine: 30)
        harness.coordinator.fulfillEditorScrollRequest()

        #expect(harness.textView.selectedRange() == originalCaret)
        #expect(scrollView.contentView.bounds.origin.y > 0)
        #expect(harness.model.editorScrollRequest == nil)
    }

    private func makeHarness(text: String, height: CGFloat = 400) -> Harness {
        let document = EditorDocument()
        document.setText(text)
        let model = EditorModel(document: document)
        let coordinator = EditorTextView.Coordinator(model: model)
        let textView = EditorNSTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: max(height, 400)))
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = model.textSnapshot()
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 500, height: height))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        coordinator.attach(to: textView)
        return Harness(document: document, model: model,
                       coordinator: coordinator, textView: textView)
    }

    private struct Harness {
        let document: EditorDocument
        let model: EditorModel
        let coordinator: EditorTextView.Coordinator
        let textView: EditorNSTextView
    }
}
