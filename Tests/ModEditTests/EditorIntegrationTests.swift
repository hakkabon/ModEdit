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
        #expect(harness.model.cursorColumn == 3)
    }

    @Test func endOfBufferStaysOnLastExistingLine() {
        let harness = makeHarness(text: "first\nsecond")

        harness.textView.setSelectedRange(NSRange(location: harness.textView.string.utf16.count,
                                                   length: 0))

        #expect(harness.model.cursorLine == 2)
        #expect(harness.model.cursorColumn == 6)
    }

    @Test func trailingNewlineCreatesARealEmptyLine() {
        let harness = makeHarness(text: "first\n")
        harness.textView.setSelectedRange(NSRange(location: harness.textView.string.utf16.count,
                                                   length: 0))
        #expect(harness.model.cursorLine == 2)
        #expect(harness.model.cursorColumn == 1)
    }

    @Test func sameLineCountDeletionKeepsCursorLineCorrect() {
        let harness = makeHarness(text: "one\ntwo\nthree")

        // Deleting inside the first line does not change the line count, but
        // every later line start shifts one UTF-16 unit left.
        harness.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 2, length: 1), with: "")
        harness.textView.setSelectedRange(NSRange(location: 7, length: 0))

        #expect(harness.document.content.text == "on\ntwo\nthree")
        #expect(harness.model.lineCount == 3)
        #expect(harness.model.cursorLine == 3)
        #expect(harness.model.cursorColumn == 1)
    }

    @Test func sameLineCountInsertionKeepsCursorLineCorrect() {
        let harness = makeHarness(text: "one\ntwo\nthree")

        harness.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 0), with: "abcde")
        harness.textView.setSelectedRange(NSRange(location: 13, length: 0))

        #expect(harness.model.lineCount == 3)
        #expect(harness.model.cursorLine == 3)
        #expect(harness.model.cursorColumn == 1)
    }

    @Test func externalReplacementWithSameLineCountRefreshesModel() async {
        let harness = makeHarness(text: "aaa\nbbb\nccc")

        harness.document.setText("a\nbb\nccc")
        harness.coordinator.synchronizeFromDocumentIfNeeded()
        await Task.yield()
        harness.textView.setSelectedRange(NSRange(location: 5, length: 0))

        #expect(harness.textView.string == "a\nbb\nccc")
        #expect(harness.model.lineCount == 3)
        #expect(harness.model.cursorLine == 3)
        #expect(harness.model.cursorColumn == 1)
        #expect(harness.model.textRevision == harness.document.textGeneration)
    }

    @Test func gutterDoesNotInventLineAfterUnterminatedLastRow() {
        let index = LineIndex(text: "one\ntwo\nthree")
        #expect(!index.isLineStart(at: 13))
    }

    @Test func gutterIncludesEmptyRowAfterTrailingNewline() {
        let index = LineIndex(text: "one\ntwo\nthree\n")
        #expect(index.isLineStart(at: 14))
    }

    @Test func carriageReturnDocumentsHaveCorrectFinalPosition() {
        let harness = makeHarness(text: "one\rtwo\rthree")
        harness.textView.setSelectedRange(NSRange(location: harness.textView.string.utf16.count,
                                                   length: 0))
        #expect(harness.model.lineCount == 3)
        #expect(harness.model.cursorLine == 3)
        #expect(harness.model.cursorColumn == 5)
    }

    @Test func gutterCurrentRowFollowsSelection() {
        let harness = makeHarness(text: "one\ntwo\nthree")
        let scrollView = NSScrollView()
        scrollView.documentView = harness.textView
        let gutter = LineNumberRulerView(textView: harness.textView,
                                         scrollView: scrollView,
                                         lineSource: harness.model)
        scrollView.verticalRulerView = gutter

        harness.textView.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(gutter.currentLine == 2)
        harness.textView.setSelectedRange(NSRange(location: 9, length: 0))
        #expect(gutter.currentLine == 3)
    }

    @Test func lineIndexMapsOpenedDocumentRows() {
        let index = LineIndex(text: "one\ntwo\nthree")
        #expect(index.starts == [0, 4, 8])
        #expect(index.lineAndColumn(at: 0).line == 1)
        #expect(index.lineAndColumn(at: 4).line == 2)
        #expect(index.lineAndColumn(at: 8).line == 3)
    }

    @Test func insertedLinesUpdateModelAndForceGutterRedraw() {
        let harness = makeHarness(text: "one")
        let scrollView = NSScrollView()
        scrollView.documentView = harness.textView
        let gutter = LineNumberRulerView(textView: harness.textView,
                                         scrollView: scrollView,
                                         lineSource: harness.model)
        harness.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 3, length: 0), with: "\n\nthree")
        gutter.updateLineCount(harness.model.lineCount)

        #expect(harness.model.lineCount == 3)
        #expect(gutter.displayedLineCount == 3)
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
        let document = EditorDocument()
        let model = EditorModel(document: document)
        let textView = NSTextView(usingTextLayoutManager: true)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        let gutter = LineNumberRulerView(textView: textView,
                                         scrollView: scrollView,
                                         lineSource: model)
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
