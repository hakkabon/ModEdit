import Testing
import AppKit
@testable import ModEditCore

@Suite("Rendered editing", .serialized)
@MainActor
struct RenderedEditingTests {

    @Test func hidesMarkupOutsideTheCaretLine() {
        let source = "A **bold** word\n\nsecond\n"
        let harness = makeHarness(text: source, caret: source.utf16.count)
        let marker = (source as NSString).range(of: "**")

        #expect(harness.model.isRenderedEditingActive)
        #expect(isHidden(harness.textView, at: marker.location))
    }

    @Test func movingTheCaretRevealsThatLinesMarkup() {
        let source = "A **bold** word\n\nsecond\n"
        let harness = makeHarness(text: source, caret: source.utf16.count)
        let marker = (source as NSString).range(of: "**")
        #expect(isHidden(harness.textView, at: marker.location))

        harness.textView.setSelectedRange(
            NSRange(location: marker.location, length: 0))

        #expect(!isHidden(harness.textView, at: marker.location))
        #expect(harness.model.cursorLine == 1)

        harness.textView.setSelectedRange(
            NSRange(location: source.utf16.count, length: 0))

        #expect(isHidden(harness.textView, at: marker.location))
    }

    @Test func editingKeepsSourceAndUpdatesTheProjection() {
        let source = "A **bold** word\n\nsecond\n"
        let harness = makeHarness(text: source, caret: 1)

        harness.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 1, length: 0), with: "!")

        let edited = "A! **bold** word\n\nsecond\n"
        #expect(harness.document.content.text == edited)
        #expect(harness.textView.string == edited)

        harness.textView.setSelectedRange(
            NSRange(location: edited.utf16.count, length: 0))
        harness.coordinator.applyRenderedProjection(full: true)
        let marker = (edited as NSString).range(of: "**")
        #expect(isHidden(harness.textView, at: marker.location))
    }

    @Test func disablingRenderedEditingRestoresSourceHighlighting() {
        let source = "A **bold** word\n\nsecond\n"
        let harness = makeHarness(text: source, caret: source.utf16.count)
        let marker = (source as NSString).range(of: "**")
        #expect(isHidden(harness.textView, at: marker.location))

        harness.model.showsRenderedEditing = false
        harness.coordinator.modelDidChange()
        harness.coordinator.applySourceHighlightingNow()

        #expect(!harness.model.isRenderedEditingActive)
        #expect(!isHidden(harness.textView, at: marker.location))
        #expect(harness.textView.textStorage?.attribute(
            .kern, at: marker.location, effectiveRange: nil) == nil)
    }

    @Test func headingTextIsLargerOutsideTheCaretLine() {
        let source = "# Heading\n\nBody\n"
        let harness = makeHarness(text: source, caret: source.utf16.count)
        let heading = (source as NSString).range(of: "Heading")

        let font = harness.textView.textStorage?
            .attribute(.font, at: heading.location, effectiveRange: nil) as? NSFont

        #expect(font?.pointSize ?? 0 > 13)
    }

    @Test func formatsWithoutRenderedSupportDisableTheMode() {
        let harness = makeHarness(text: "# Heading\n")
        #expect(harness.model.supportsRenderedEditing)

        harness.model.setFormat(PlainTextFormat())

        #expect(!harness.model.supportsRenderedEditing)
        #expect(!harness.model.showsRenderedEditing)
        #expect(!harness.model.isRenderedEditingActive)
    }

    @Test func toggleRenderedEditingTurnsTheModeOnAndOff() {
        let harness = makeHarness(text: "# Heading\n")
        #expect(harness.model.isRenderedEditingActive)

        harness.model.toggleRenderedEditing()
        #expect(!harness.model.showsRenderedEditing)
        #expect(!harness.model.isRenderedEditingActive)

        harness.model.toggleRenderedEditing()
        #expect(harness.model.showsRenderedEditing)
        #expect(harness.model.isRenderedEditingActive)
    }

    @Test func oversizedDocumentsStayInSourceMode() {
        let text = String(
            repeating: "a",
            count: EditorModel.maximumRenderedEditingLength + 1)
        let document = EditorDocument()
        document.setText(text)
        let model = EditorModel(document: document)
        model.setFormat(MarkdownFormat())

        #expect(model.supportsRenderedEditing)
        #expect(!model.canUseRenderedEditing)
        model.toggleRenderedEditing()
        #expect(!model.showsRenderedEditing)
        #expect(!model.isRenderedEditingActive)
    }

    @Test func undoAfterRenderedEditKeepsTheSourceCorrect() throws {
        let harness = makeHarness(text: "abc\n", caret: 3)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = harness.textView
        window.makeFirstResponder(harness.textView)

        harness.textView.insertText(
            "!", replacementRange: NSRange(location: 3, length: 0))
        harness.coordinator.applyRenderedProjection(full: true)
        #expect(harness.document.content.text == "abc!\n")

        let undoManager = try #require(harness.textView.undoManager)
        #expect(undoManager.canUndo)
        undoManager.undo()

        #expect(harness.textView.string == "abc\n")
        #expect(harness.document.content.text == "abc\n")
        harness.coordinator.applyRenderedProjection(full: true)
    }

    @Test func extensionMovesThroughDisplayPositionsAcrossRenderedLines() throws {
        let source = "anchor\n\nA **bold** word.\n\nthird\n"
        let harness = makeHarness(text: source, caret: 0)
        let marker = (source as NSString).range(of: "**")
        let presentation = try #require(harness.coordinator.presentationForTesting)
        let anchorLine = presentation.lineRange(containing: 0)
        let expected = presentation.nextSourceOffset(
            from: marker.location, direction: 1, activeLine: anchorLine)

        // Anchor on the first line and extend the selection end through the
        // rendered paragraph. The visible end must skip the collapsed `**`.
        harness.textView.setSelectedRange(
            NSRange(location: 0, length: marker.location))
        harness.textView.moveRightAndModifySelection(nil)

        #expect(expected == marker.location + 3)
        #expect(NSMaxRange(harness.textView.selectedRange()) == expected)
    }

    @Test func arrowKeysUseTheInstalledRenderedNavigation() {
        let source = "A **bold** word\n\nsecond\n"
        let harness = makeHarness(text: source, caret: 1)

        #expect(harness.textView.renderedNavigation != nil)
        harness.textView.moveRight(nil)
        #expect(harness.textView.selectedRange().location == 2)
    }

    private func isHidden(_ textView: NSTextView, at location: Int) -> Bool {
        textView.textStorage?.attribute(
            RenderedEditorStyler.hiddenAttribute,
            at: location,
            effectiveRange: nil) != nil
    }

    private func makeHarness(text: String, caret: Int? = nil) -> Harness {
        let document = EditorDocument()
        document.setText(text)
        let model = EditorModel(document: document)
        model.setFormat(MarkdownFormat())
        let coordinator = EditorTextView.Coordinator(model: model)
        let textView = EditorNSTextView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        textView.allowsUndo = true
        textView.string = model.textSnapshot()
        coordinator.attach(to: textView)
        model.showsRenderedEditing = true
        coordinator.modelDidChange()
        if let caret {
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        }
        coordinator.applyRenderedProjection(full: true)
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
