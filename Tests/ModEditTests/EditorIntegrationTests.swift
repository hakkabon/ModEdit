import Testing
import AppKit
import Combine
@testable import ModEditCore

@Suite("Editor integration", .serialized)
@MainActor
struct EditorIntegrationTests {

    @Test func textStorageEditUpdatesDocumentIncrementally() throws {
        let harness = makeHarness(text: "alpha βeta")
        let range = (harness.textView.string as NSString).range(of: "βeta")

        harness.textView.textStorage?.replaceCharacters(in: range, with: "日本語")

        #expect(harness.document.content.text == "alpha 日本語")
        #expect(harness.model.textRevision == harness.document.textGeneration)
    }

    @Test func utf16ReplacementHandlesEmojiBoundaries() throws {
        let harness = makeHarness(text: "a👩🏽‍💻z")
        let range = (harness.textView.string as NSString).range(of: "👩🏽‍💻")

        harness.textView.textStorage?.replaceCharacters(in: range, with: "🧪")

        #expect(harness.document.content.text == "a🧪z")
    }

    @Test func externalDocumentReplacementIsPulledIntoTextView() {
        let harness = makeHarness(text: "old")
        harness.document.setText("reloaded from disk")

        harness.coordinator.synchronizeFromDocumentIfNeeded()

        #expect(harness.textView.string == "reloaded from disk")
        #expect(harness.document.content.text == "reloaded from disk")
    }

    @Test func formatSwitchUpdatesDocumentAndStartsNewHighlightingPass() {
        let harness = makeHarness(text: "# title")

        harness.model.setFormat(MarkdownFormat())
        harness.coordinator.modelDidChange()

        #expect(harness.document.content.format.id == "markdown")
        #expect(harness.model.format.id == "markdown")
    }

    @Test func undoFlowsBackIntoPersistedDocument() throws {
        let harness = makeHarness(text: "abc")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = harness.textView
        window.makeFirstResponder(harness.textView)
        harness.textView.setSelectedRange(NSRange(location: 3, length: 0))

        harness.textView.insertText("!", replacementRange: NSRange(location: 3, length: 0))
        #expect(harness.document.content.text == "abc!")
        let undoManager = try #require(harness.textView.undoManager)
        #expect(undoManager.canUndo)

        undoManager.undo()

        #expect(harness.textView.string == "abc")
        #expect(harness.document.content.text == "abc")
    }

    @Test func saveSnapshotContainsLatestIncrementalEdits() throws {
        let harness = makeHarness(text: "first")
        harness.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 5, length: 0), with: " second")

        let snapshot = try harness.document.snapshot(contentType: .plainText)

        #expect(snapshot.text == "first second")
        #expect(snapshot.encoding == .utf8)
    }

    @Test func editsNotifyDocumentForAutosave() {
        let harness = makeHarness(text: "before")
        var changeCount = 0
        let subscription = harness.document.objectWillChange.sink { changeCount += 1 }

        harness.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 6), with: "after")

        #expect(changeCount == 1)
        withExtendedLifetime(subscription) {}
    }

    @Test func cursorLocationIsOneBased() {
        let harness = makeHarness(text: "first\nsecond")

        harness.textView.setSelectedRange(NSRange(location: 9, length: 0))

        #expect(harness.model.cursorLine == 2)
        #expect(harness.model.cursorColumn == 4)
    }

    @Test func cleanStateTracksSavedGenerationWithoutHidingNewerEdits() async throws {
        let harness = makeHarness(text: "one")
        harness.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 3, length: 0), with: " two")
        let firstSnapshot = try harness.document.snapshot(contentType: .plainText)
        harness.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 7, length: 0), with: " three")

        harness.document.recordSuccessfulWrite(generation: firstSnapshot.generation)
        await Task.yield()
        #expect(harness.model.isDocumentDirty)

        let latestSnapshot = try harness.document.snapshot(contentType: .plainText)
        harness.document.recordSuccessfulWrite(generation: latestSnapshot.generation)
        await Task.yield()
        #expect(!harness.model.isDocumentDirty)
    }

    @Test func lineNumberGutterExpandsForMoreDigits() {
        let textView = NSTextView(usingTextLayoutManager: true)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        let gutter = LineNumberRulerView(textView: textView, scrollView: scrollView)
        let initialWidth = gutter.ruleThickness

        gutter.updateLineCount(10_001)

        #expect(gutter.ruleThickness > initialWidth)
    }

    private func makeHarness(text: String) -> Harness {
        let document = EditorDocument()
        document.setText(text)
        let model = EditorModel(document: document)
        let coordinator = EditorTextView.Coordinator(model: model)
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.allowsUndo = true
        textView.string = model.textSnapshot()
        coordinator.attach(to: textView)
        return Harness(document: document, model: model,
                       coordinator: coordinator, textView: textView)
    }

    private struct Harness {
        let document: EditorDocument
        let model: EditorModel
        let coordinator: EditorTextView.Coordinator
        let textView: NSTextView
    }
}
