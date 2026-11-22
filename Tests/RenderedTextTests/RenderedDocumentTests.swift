import Foundation
import Testing
@testable import RenderedText

@Suite("Rendered document")
struct RenderedDocumentTests {
    private func makeBlock(kind: RenderedBlockKind = .paragraph,
                           range: Range<Int>,
                           text: String,
                           occurrence: Int = 0,
                           role: RenderedRunRole = .text) -> RenderedBlock {
        RenderedBlock(
            id: BlockID(
                kind: kind,
                contentHash: StableHash.fnv1a(text),
                occurrence: occurrence),
            kind: kind,
            sourceRange: range,
            runs: [RenderedRun(sourceRange: range, displayText: text, role: role)])
    }

    private func makeBlock(kind: RenderedBlockKind = .paragraph,
                           range: Range<Int>,
                           id: BlockID,
                           runs: [RenderedRun]) -> RenderedBlock {
        RenderedBlock(id: id, kind: kind, sourceRange: range, runs: runs)
    }

    @Test func joinsDisplayTextAcrossBlocks() throws {
        let source = "ab\ncd"
        let first = makeBlock(range: 0..<2, text: "ab")
        let second = makeBlock(range: 2..<5, text: "\ncd", occurrence: 1)
        let document = try RenderedDocument(source: source, blocks: [first, second])
        #expect(document.displayText == "ab\ncd")
        #expect(document.displayLength == 5)
        #expect(document.sourceLength == 5)
    }

    @Test func rejectsBlockGaps() {
        let source = "abcd"
        let first = makeBlock(range: 0..<2, text: "ab")
        let second = makeBlock(range: 3..<4, text: "d")
        #expect(throws: RenderedDocumentError.blockGap(expected: 2, actual: 3)) {
            try RenderedDocument(source: source, blocks: [first, second])
        }
    }

    @Test func rejectsTrailingSourceGap() {
        let source = "abcd"
        let block = makeBlock(range: 0..<2, text: "ab")
        #expect(throws: RenderedDocumentError.blockGap(expected: 2, actual: 4)) {
            try RenderedDocument(source: source, blocks: [block])
        }
    }

    @Test func rejectsOverlappingBlocks() {
        let source = "abcd"
        let first = makeBlock(range: 0..<3, text: "abc")
        let second = makeBlock(range: 2..<4, text: "cd", occurrence: 1)
        #expect(throws: RenderedDocumentError.overlappingBlock(second.id)) {
            try RenderedDocument(source: source, blocks: [first, second])
        }
    }

    @Test func rejectsBlocksOutsideTheSource() {
        let source = "abc"
        let block = makeBlock(range: 0..<4, text: "abc")
        #expect(throws: RenderedDocumentError.blockOutsideSource(block.id)) {
            try RenderedDocument(source: source, blocks: [block])
        }
    }

    @Test func rejectsEmptyBlockRanges() {
        let block = makeBlock(range: 0..<0, text: "")
        #expect(throws: RenderedDocumentError.blockOutsideSource(block.id)) {
            try RenderedDocument(source: "", blocks: [block])
        }
    }

    @Test func rejectsDuplicateBlockIDs() {
        let source = "ab"
        let first = makeBlock(range: 0..<1, text: "a")
        let second = makeBlock(range: 1..<2, text: "b")
        let duplicate = RenderedBlock(
            id: first.id,
            kind: .paragraph,
            sourceRange: 1..<2,
            runs: [RenderedRun(sourceRange: 1..<2, displayText: "b")])
        #expect(throws: RenderedDocumentError.duplicateBlockID(first.id)) {
            try RenderedDocument(source: source, blocks: [first, duplicate])
        }
        // Sanity check: distinct IDs are accepted.
        #expect(throws: Never.self) {
            try RenderedDocument(source: source, blocks: [first, second])
        }
    }

    @Test func rejectsRunGaps() {
        let source = "abcd"
        let id = BlockID(kind: .paragraph, contentHash: 1, occurrence: 0)
        let block = makeBlock(
            range: 0..<4,
            id: id,
            runs: [
                RenderedRun(sourceRange: 0..<2, displayText: "ab"),
                RenderedRun(sourceRange: 3..<4, displayText: "d"),
            ])
        #expect(throws: RenderedDocumentError.runGap(block: id, expected: 2, actual: 3)) {
            try RenderedDocument(source: source, blocks: [block])
        }
    }

    @Test func rejectsOverlappingRuns() {
        let source = "abcd"
        let id = BlockID(kind: .paragraph, contentHash: 1, occurrence: 0)
        let block = makeBlock(
            range: 0..<4,
            id: id,
            runs: [
                RenderedRun(sourceRange: 0..<3, displayText: "abc"),
                RenderedRun(sourceRange: 2..<4, displayText: "cd"),
            ])
        #expect(throws: RenderedDocumentError.overlappingRun(id)) {
            try RenderedDocument(source: source, blocks: [block])
        }
    }

    @Test func rejectsEmptyRuns() {
        let source = "a"
        let id = BlockID(kind: .paragraph, contentHash: 1, occurrence: 0)
        let block = makeBlock(
            range: 0..<1,
            id: id,
            runs: [
                RenderedRun(sourceRange: 0..<0, displayText: "", role: .hiddenSyntax),
                RenderedRun(sourceRange: 0..<1, displayText: "a"),
            ])
        #expect(throws: RenderedDocumentError.emptyRun(id)) {
            try RenderedDocument(source: source, blocks: [block])
        }
    }

    @Test func rejectsRunsOutsideTheirBlock() {
        let source = "abc"
        let id = BlockID(kind: .paragraph, contentHash: 1, occurrence: 0)
        let block = makeBlock(
            range: 0..<3,
            id: id,
            runs: [RenderedRun(sourceRange: 0..<4, displayText: "abc")])
        #expect(throws: RenderedDocumentError.runOutsideBlock(id)) {
            try RenderedDocument(source: source, blocks: [block])
        }
    }

    @Test func rejectsEmptyVisibleRuns() {
        let source = "a"
        let id = BlockID(kind: .paragraph, contentHash: 1, occurrence: 0)
        let block = makeBlock(
            range: 0..<1,
            id: id,
            runs: [RenderedRun(sourceRange: 0..<1, displayText: "", role: .text)])
        #expect(throws: RenderedDocumentError.emptyVisibleRun(id)) {
            try RenderedDocument(source: source, blocks: [block])
        }
    }

    @Test func allowsEmptyHiddenRuns() throws {
        let source = "#"
        let id = BlockID(kind: .heading, contentHash: 1, occurrence: 0)
        let block = makeBlock(
            range: 0..<1,
            id: id,
            runs: [RenderedRun(sourceRange: 0..<1, displayText: "", role: .hiddenSyntax)])
        let document = try RenderedDocument(source: source, blocks: [block])
        #expect(document.displayText == "")
        #expect(document.displayLength == 0)
        #expect(document.map.displayOffset(for: 1) == 0)
        #expect(document.map.sourceOffset(for: 0, affinity: .leading) == 0)
        #expect(document.map.sourceOffset(for: 0, affinity: .trailing) == 1)
    }

    @Test func findsBlocksAtBoundaries() throws {
        let document = try MarkdownRenderer().render("# A\n\npara\n")
        #expect(document.block(containingSourceOffset: 0)?.kind == .heading)
        #expect(document.block(containingSourceOffset: 2)?.kind == .heading)
        #expect(document.block(containingSourceOffset: 3)?.kind == .blank)
        #expect(document.block(containingSourceOffset: 4)?.kind == .blank)
        #expect(document.block(containingSourceOffset: 5)?.kind == .paragraph)
        #expect(document.block(containingSourceOffset: document.sourceLength)?.kind == .blank)
        #expect(document.block(containingSourceOffset: -1) == nil)
        #expect(document.block(containingSourceOffset: document.sourceLength + 1) == nil)
    }

    @Test func sourceTextClampsToTheDocument() throws {
        let document = try RenderedDocument(source: "abcd", blocks: [
            makeBlock(range: 0..<4, text: "abcd"),
        ])
        #expect(document.sourceText(in: 1..<3) == "bc")
        #expect(document.sourceText(in: -5..<2) == "ab")
        #expect(document.sourceText(in: 2..<100) == "cd")
    }

    @Test func invalidatesInsertionsAtBothSidesOfABoundary() throws {
        let document = try MarkdownRenderer().render("# A\n\npara\n\n- item\n")
        let heading = document.blocks[0]
        let blank = document.blocks[1]
        let paragraph = document.blocks[2]
        let secondBlank = document.blocks[3]

        #expect(document.invalidatedBlockIDs(
            for: SourceEdit(range: 1..<1, replacement: "x")) == [heading.id])
        #expect(document.invalidatedBlockIDs(
            for: SourceEdit(
                range: heading.sourceRange.upperBound..<heading.sourceRange.upperBound,
                replacement: "x")) == [heading.id, blank.id])
        #expect(document.invalidatedBlockIDs(
            for: SourceEdit(range: paragraph.sourceRange, replacement: "x")) == [paragraph.id])
        #expect(document.invalidatedBlockIDs(
            for: SourceEdit(
                range: paragraph.sourceRange.lowerBound..<secondBlank.sourceRange.upperBound,
                replacement: "x")) == [paragraph.id, secondBlank.id])
        #expect(document.invalidatedBlockIDs(
            for: SourceEdit(
                range: heading.sourceRange.upperBound..<paragraph.sourceRange.upperBound,
                replacement: "x")) == [blank.id, paragraph.id])
        let last = try #require(document.blocks.last)
        #expect(document.invalidatedBlockIDs(
            for: SourceEdit(
                range: document.sourceLength..<document.sourceLength,
                replacement: "x")) == [last.id])
        #expect(document.invalidatedBlockIDs(
            for: SourceEdit(
                range: (document.sourceLength + 5)..<(document.sourceLength + 5),
                replacement: "x")).isEmpty)
    }

    @Test func sourceEditReportsReplacementLength() {
        let edit = SourceEdit(range: 2..<5, replacement: "😀")
        #expect(edit.replacementLength == 2)
        #expect(edit.range == 2..<5)
    }
}
