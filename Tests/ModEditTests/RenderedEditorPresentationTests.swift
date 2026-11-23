import Testing
import Foundation
import RenderedText
@testable import ModEditCore

@Suite("Rendered editor presentation")
struct RenderedEditorPresentationTests {

    @Test func collapsedSyntaxOutsideTheActiveLineIsHidden() throws {
        let source = "# Heading\n\nA **bold** word.\n"
        let presentation = try RenderedEditorPresentation(source: source)
        let marker = (source as NSString).range(of: "**")
        let headingLine = presentation.lineRange(containing: 0)
        let boldLine = presentation.lineRange(containing: marker.location)

        let hidden = span(in: presentation, at: marker.location, activeLine: headingLine)
        #expect(hidden?.isHidden == true)
        #expect(hidden?.isRaw == false)

        let raw = span(in: presentation, at: marker.location, activeLine: boldLine)
        #expect(raw?.isRaw == true)
        #expect(raw?.isHidden == false)
    }

    @Test func headingMarkerCollapsesAndHeadingTextKeepsItsSemantics() throws {
        let source = "# Heading\n\nBody\n"
        let presentation = try RenderedEditorPresentation(source: source)
        let bodyLine = presentation.lineRange(
            containing: (source as NSString).range(of: "Body").location)

        let marker = span(in: presentation, at: 0, activeLine: bodyLine)
        #expect(marker?.isHidden == true)

        let headingIndex = (source as NSString).range(of: "Heading").location
        let heading = span(in: presentation, at: headingIndex, activeLine: bodyLine)
        #expect(heading?.isHidden == false)
        #expect(heading?.attributes.headingLevel == 1)
    }

    @Test func referenceDefinitionsCollapseButRevealOnTheirLine() throws {
        let source = "Text\n\n[ref]: https://example.com\n"
        let presentation = try RenderedEditorPresentation(source: source)
        let referenceIndex = (source as NSString).range(of: "[ref]").location
        let referenceLine = presentation.lineRange(containing: referenceIndex)
        let textLine = presentation.lineRange(containing: 0)

        let hidden = span(in: presentation, at: referenceIndex, activeLine: textLine)
        #expect(hidden?.isHidden == true)

        let raw = span(in: presentation, at: referenceIndex, activeLine: referenceLine)
        #expect(raw?.isRaw == true)
        #expect(raw?.sourceRange.contains(referenceIndex) == true)
    }

    @Test func substitutionsStayVisible() throws {
        let source = "half &amp; half\n"
        let presentation = try RenderedEditorPresentation(source: source)
        let entity = (source as NSString).range(of: "&amp;")
        let span = self.span(in: presentation, at: entity.location, activeLine: nil)

        #expect(span?.isHidden == false)
        #expect(span?.role == .text)
    }

    @Test func incrementalEditsMatchAFreshPresentation() throws {
        var incremental = try RenderedEditorPresentation(source: "One\n\nTwo\n")
        try incremental.apply(SourceEdit(range: 3..<3, replacement: "!"))

        let fresh = try RenderedEditorPresentation(source: "One!\n\nTwo\n")

        #expect(incremental.source == fresh.source)
        #expect(incremental.spans(activeLine: nil) == fresh.spans(activeLine: nil))
        #expect(incremental.displayLength == fresh.displayLength)
    }

    @Test func caretSkipsCollapsedMarkersOutsideTheActiveLine() throws {
        let source = "A **bold** word\n\nsecond\n"
        let presentation = try RenderedEditorPresentation(source: source)
        let secondLine = presentation.lineRange(
            containing: (source as NSString).range(of: "second").location)

        // Moving right from the space after "A" lands on "b", skipping both
        // opening asterisks. Moving left from "b" lands back on the space.
        #expect(presentation.nextSourceOffset(
            from: 1, direction: 1, activeLine: secondLine) == 4)
        #expect(presentation.nextSourceOffset(
            from: 4, direction: -1, activeLine: secondLine) == 1)

        // Moving right from the start of the closing asterisks skips them and
        // the displayed space after the emphasis.
        #expect(presentation.nextSourceOffset(
            from: 8, direction: 1, activeLine: secondLine) == 11)
    }

    @Test func caretMovesThroughLiteralSourceInsideTheActiveLine() throws {
        let source = "A **bold** word\n\nsecond\n"
        let presentation = try RenderedEditorPresentation(source: source)
        let firstLine = presentation.lineRange(containing: 1)

        #expect(presentation.nextSourceOffset(
            from: 1, direction: 1, activeLine: firstLine) == 2)
        #expect(presentation.nextSourceOffset(
            from: 2, direction: 1, activeLine: firstLine) == 3)
    }

    @Test func caretMovementClampsAtTheDocumentEdges() throws {
        let source = "A **bold** word\n\nsecond\n"
        let presentation = try RenderedEditorPresentation(source: source)
        let secondLine = presentation.lineRange(
            containing: (source as NSString).range(of: "second").location)

        #expect(presentation.nextSourceOffset(
            from: 0, direction: -1, activeLine: secondLine) == 0)
        #expect(presentation.nextSourceOffset(
            from: presentation.sourceLength, direction: 1,
            activeLine: secondLine) == presentation.sourceLength)
    }

    @Test func lineRangeAtATrailingNewlineIsTheEmptyFinalLine() throws {
        let presentation = try RenderedEditorPresentation(source: "a\n")

        #expect(presentation.lineRange(containing: 2) == 2..<2)
    }

    @Test func spansAreLimitedToTheRequestedRange() throws {
        let source = "# One\n\nTwo\n"
        let presentation = try RenderedEditorPresentation(source: source)
        let line = presentation.lineRange(containing: 0)
        let spans = presentation.spans(intersecting: line, activeLine: nil)

        #expect(!spans.isEmpty)
        #expect(spans.allSatisfy { $0.sourceRange.overlaps(line) })
    }

    private func span(in presentation: RenderedEditorPresentation,
                      at location: Int,
                      activeLine: Range<Int>?) -> RenderedEditorSpan? {
        presentation.spans(
            intersecting: location..<(location + 1),
            activeLine: activeLine)
            .first { $0.sourceRange.contains(location) }
    }
}
