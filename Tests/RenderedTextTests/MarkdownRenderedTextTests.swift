import Foundation
import Testing
@testable import RenderedText

@Suite("Incremental Markdown rendering")
struct MarkdownRenderedTextTests {
    private func range(of needle: String,
                       in source: String,
                       from start: Int = 0) -> Range<Int>? {
        let text = source as NSString
        let lower = max(0, min(start, text.length))
        let found = text.range(
            of: needle,
            options: [],
            range: NSRange(location: lower, length: text.length - lower))
        guard found.location != NSNotFound else { return nil }
        return found.location..<(found.location + found.length)
    }

    @Test func editReusesUnchangedBlocksAndRerendersTheEditedOne() throws {
        let source = "# Title\n\nHello world.\n\n- item\n"
        var text = try MarkdownRenderedText(source: source)
        let headingID = text.document.blocks[0].id
        let paragraphID = text.document.blocks[2].id
        let listID = text.document.blocks[4].id

        let world = try #require(range(of: "world", in: source))
        let invalidated = try text.replaceText(in: world, with: "there")

        #expect(invalidated == [paragraphID])
        #expect(text.lastInvalidatedBlockIDs == [paragraphID])
        #expect(text.lastRenderedBlockIDs.count == 1)
        #expect(!text.lastRenderedBlockIDs.contains(paragraphID))
        #expect(text.lastReusedBlockIDs.contains(headingID))
        #expect(text.lastReusedBlockIDs.contains(listID))
        #expect(text.document.source == "# Title\n\nHello there.\n\n- item\n")
        #expect(text.document.displayText.contains("Hello there."))
        #expect(text.document.displayText.contains("Title"))
        #expect(text.document.displayText.contains("• item"))
    }

    @Test func insertingAtTheEndRendersOnlyNewBlocks() throws {
        let source = "# Title\n\nHello.\n"
        var text = try MarkdownRenderedText(source: source)
        let headingID = text.document.blocks[0].id
        let paragraphID = text.document.blocks[2].id
        let oldLast = try #require(text.document.blocks.last)

        let invalidated = try text.replaceText(
            in: text.document.sourceLength..<text.document.sourceLength,
            with: "\nAdded paragraph.\n")

        #expect(invalidated == [oldLast.id])
        #expect(text.lastReusedBlockIDs.contains(headingID))
        #expect(text.lastReusedBlockIDs.contains(paragraphID))
        #expect(text.lastRenderedBlockIDs.count >= 2)
        #expect(text.document.displayText.contains("Added paragraph."))
        #expect(text.document.source.hasSuffix("Added paragraph.\n"))
    }

    @Test func insertingAtTheStartKeepsExistingBlocks() throws {
        let source = "# Title\n\nHello.\n"
        var text = try MarkdownRenderedText(source: source)
        let oldBlocks = Set(text.document.blocks.map(\.id))
        let oldFirst = try #require(text.document.blocks.first)

        let invalidated = try text.replaceText(
            in: 0..<0,
            with: "# New\n\n")

        #expect(invalidated == [oldFirst.id])
        #expect(text.lastReusedBlockIDs == oldBlocks)
        #expect(text.lastRenderedBlockIDs.count == 2)
        #expect(text.document.source.hasPrefix("# New\n\n# Title\n"))
        #expect(text.document.displayText.contains("New"))
        #expect(text.document.displayText.contains("Hello."))
    }

    @Test func deletingTheBlankLineMergesParagraphs() throws {
        let source = "first\n\nsecond\n"
        var text = try MarkdownRenderedText(source: source)

        // Delete the blank line's newline, leaving a single newline.
        _ = try text.replaceText(in: 6..<7, with: "")

        #expect(text.document.source == "first\nsecond\n")
        let paragraphs = text.document.blocks.filter { $0.kind == .paragraph }
        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].displayText == "first second")
        #expect(!text.document.blocks.contains { $0.kind == .blank && $0.displayText == "\n\n" })
    }

    @Test func applyingMultipleEditsKeepsOffsetsCorrect() throws {
        var text = try MarkdownRenderedText(source: "Hello world.\n")
        let hello = try #require(range(of: "Hello", in: text.document.source))
        _ = try text.replaceText(in: hello, with: "Hi")

        let world = try #require(range(of: "world", in: text.document.source))
        _ = try text.replaceText(in: world, with: "there")

        #expect(text.document.source == "Hi there.\n")
        #expect(text.document.displayText.hasPrefix("Hi there."))

        let emoji = try #require(range(of: "there", in: text.document.source))
        _ = try text.replaceText(in: emoji, with: "😀")
        #expect(text.document.source == "Hi 😀.\n")
        #expect(text.document.displayText.hasPrefix("Hi 😀."))
    }

    @Test func editingInlineMarkupRerendersTheParagraph() throws {
        var text = try MarkdownRenderedText(source: "*em* and **strong**\n")
        let strong = try #require(range(of: "strong", in: text.document.source))
        _ = try text.replaceText(in: strong, with: "bold")
        #expect(text.document.displayText.hasPrefix("em and bold"))
        let paragraph = try #require(text.document.blocks.first { $0.kind == .paragraph })
        #expect(paragraph.runs.contains { $0.displayText == "bold" && $0.attributes.isStrong })
    }

    @Test func editingOneOfTwoIdenticalBlocksStaysValid() throws {
        var text = try MarkdownRenderedText(source: "same\n\nsame\n")
        let first = try #require(range(of: "same", in: text.document.source))
        _ = try text.replaceText(in: first, with: "different")
        #expect(text.document.source == "different\n\nsame\n")
        let paragraphs = text.document.blocks.filter { $0.kind == .paragraph }
        #expect(paragraphs.map(\.displayText) == ["different", "same"])
        #expect(Set(paragraphs.map(\.id)).count == 2)
    }

    @Test func rejectsEditsOutsideTheSource() throws {
        var text = try MarkdownRenderedText(source: "abc\n")
        let before = text.document
        #expect(throws: RenderedDocumentError.invalidEditRange) {
            try text.replaceText(
                in: 0..<(text.document.sourceLength + 1),
                with: "x")
        }
        #expect(text.document == before)
        #expect(text.lastRenderedBlockIDs.isEmpty)
        #expect(text.lastReusedBlockIDs.isEmpty)
    }

    @Test func incrementalDocumentsMatchFreshRenders() throws {
        let edits: [(Range<Int>, String)] = [
            (0..<0, "# Added\n\n"),
            (9..<9, "!"),
            (2..<4, ""),
        ]
        var source = "# Title\n\nParagraph.\n"
        var incremental = try MarkdownRenderedText(source: source)

        for (range, replacement) in edits where range.upperBound <= source.utf16.count {
            source = (source as NSString).replacingCharacters(
                in: NSRange(location: range.lowerBound, length: range.count),
                with: replacement)
            _ = try incremental.replaceText(in: range, with: replacement)
            let fresh = try MarkdownRenderer().render(source)
            #expect(incremental.document.source == fresh.source)
            #expect(incremental.document.displayText == fresh.displayText)
            #expect(incremental.document.blocks.map(\.sourceRange)
                == fresh.blocks.map(\.sourceRange))
        }
    }
}
