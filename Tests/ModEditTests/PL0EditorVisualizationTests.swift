import AppKit
import PL0Language
import Testing
@testable import ModEditCore

@Suite("PL/0 editor visualization", .serialized)
@MainActor
struct PL0EditorVisualizationTests {
    @Test func parseResultProjectsProblemsAndBothRecoveryKinds() {
        let result = PL0Frontend().parse(SourceSnapshot(
            version: 7, text: "var x; begin x := @ 1; if odd x x := 2 end."))
        let visualization = PL0EditorVisualization(result: result)

        #expect(visualization.version == 7)
        #expect(visualization.problemCount == result.diagnostics.count)
        #expect(visualization.recoveryCount == result.recovery.events.count)
        #expect(visualization.annotations.contains { $0.kind == .error })
        #expect(visualization.annotations.contains { $0.kind == .missingToken })
        #expect(visualization.annotations.contains { $0.kind == .skippedToken })
    }

    @Test func modelRejectsStaleResultsAndClearsMarkersOnEdit() throws {
        let harness = makeHarness(text: "var x; if odd x x := 1.")
        let firstVersion = harness.model.textRevision
        let first = PL0Frontend().parse(SourceSnapshot(
            version: firstVersion, text: harness.model.textSnapshot()))

        harness.model.publishPL0Visualization(first)
        #expect(harness.model.pl0Visualization?.version == firstVersion)

        let length = (harness.model.textSnapshot() as NSString).length
        harness.model.applyTextEdit(editedRange: NSRange(location: length, length: 1),
                                    delta: 1, replacement: " ")
        #expect(harness.model.pl0Visualization == nil)

        harness.model.publishPL0Visualization(first)
        #expect(harness.model.pl0Visualization == nil)
    }

    @Test func temporaryAttributesVisualizeProblemsWithoutChangingStorage() throws {
        let source = "var x; if odd @ 1 x := 1."
        let harness = makeHarness(text: source)
        let result = PL0Frontend().parse(SourceSnapshot(
            version: harness.model.textRevision, text: source))
        harness.model.publishPL0Visualization(result)

        harness.coordinator.refreshParserVisualization()

        let diagnostic = try #require(result.diagnostics.first)
        let index = min(diagnostic.range.location, (source as NSString).length - 1)
        let underline = harness.textView.layoutManager?.temporaryAttribute(
            .underlineStyle, atCharacterIndex: index, effectiveRange: nil)
        #expect(underline != nil)

        let missing = try #require(result.recovery.events.first {
            if case .insert = $0.action { true } else { false }
        })
        let missingIndex = min(missing.action.range.location,
                               (source as NSString).length - 1)
        #expect(harness.textView.layoutManager?.temporaryAttribute(
            .backgroundColor, atCharacterIndex: missingIndex,
            effectiveRange: nil) != nil)

        let skipped = try #require(result.recovery.events.first {
            if case .delete = $0.action { true } else { false }
        })
        #expect(harness.textView.layoutManager?.temporaryAttribute(
            .strikethroughStyle, atCharacterIndex: skipped.action.range.location,
            effectiveRange: nil) != nil)
        #expect(harness.textView.string == source)
        #expect(harness.textView.textStorage?.editedMask.contains(.editedCharacters) == false)

        harness.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 0), with: " ")
        #expect(harness.textView.layoutManager?.temporaryAttribute(
            .strikethroughStyle,
            atCharacterIndex: skipped.action.range.location + 1,
            effectiveRange: nil) == nil)
        #expect(harness.textView.layoutManager?.temporaryAttribute(
            .backgroundColor, atCharacterIndex: missingIndex + 1,
            effectiveRange: nil) == nil)
    }

    @Test func revealRequestSelectsAndClampsTheSourceRange() {
        let harness = makeHarness(text: "begin call p end.")

        harness.model.revealSourceRange(SourceRange(location: 6, length: 6))
        harness.coordinator.fulfillRevealRequest()
        #expect(harness.textView.selectedRange() == NSRange(location: 6, length: 6))

        harness.model.revealSourceRange(SourceRange(location: 10_000, length: 5))
        harness.coordinator.fulfillRevealRequest()
        #expect(harness.textView.selectedRange().location
                == (harness.textView.string as NSString).length)
        #expect(harness.textView.selectedRange().length == 0)
    }

    private func makeHarness(text: String) -> Harness {
        let document = EditorDocument()
        document.setText(text)
        let model = EditorModel(document: document)
        model.setFormat(PL0Format())
        let coordinator = EditorTextView.Coordinator(model: model)
        let textView = NSTextView(frame: .zero)
        textView.string = text
        coordinator.attach(to: textView)
        return Harness(model: model, coordinator: coordinator, textView: textView)
    }

    private struct Harness {
        let model: EditorModel
        let coordinator: EditorTextView.Coordinator
        let textView: NSTextView
    }
}
