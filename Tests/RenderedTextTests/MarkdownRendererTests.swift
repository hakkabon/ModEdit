import Foundation
import Testing
@testable import RenderedText

@Suite("Markdown renderer")
struct MarkdownRendererTests {
    private func render(_ source: String) throws -> RenderedDocument {
        try MarkdownRenderer().render(source)
    }

    private func block(_ document: RenderedDocument,
                       kind: RenderedBlockKind) -> RenderedBlock? {
        document.blocks.first { $0.kind == kind }
    }

    private func runs(_ block: RenderedBlock,
                      text: String) -> [RenderedRun] {
        block.runs.filter { $0.displayText == text }
    }

    private func hiddenSource(_ block: RenderedBlock,
                              in document: RenderedDocument) -> [String] {
        block.runs
            .filter { $0.role == .hiddenSyntax }
            .map { document.sourceText(in: $0.sourceRange) }
    }

    // MARK: Headings

    @Test func rendersATXHeadings() throws {
        let document = try render("# One\n\n### Three\n")
        #expect(document.blocks[0].kind == .heading)
        #expect(document.blocks[0].displayText == "One")
        #expect(document.blocks[0].runs.first?.role == .hiddenSyntax)
        #expect(document.blocks[0].runs.first?.sourceRange == 0..<2)
        #expect(document.blocks[0].runs.last?.attributes.headingLevel == 1)
        #expect(document.blocks[2].displayText == "Three")
        #expect(document.blocks[2].runs.last?.attributes.headingLevel == 3)
        #expect(hiddenSource(document.blocks[2], in: document).contains("### "))
    }

    @Test func rendersSetextHeadings() throws {
        let document = try render("One\n===\n\nTwo\n---\n")
        let headings = document.blocks.filter { $0.kind == .heading }
        #expect(headings.count == 2)
        #expect(headings[0].displayText == "One\n")
        #expect(headings[0].runs.last?.attributes.headingLevel == 1)
        #expect(hiddenSource(headings[0], in: document).contains("===\n"))
        #expect(headings[1].displayText == "Two\n")
        #expect(headings[1].runs.last?.attributes.headingLevel == 2)
        #expect(hiddenSource(headings[1], in: document).contains("---"))
    }

    // MARK: Inline markup

    @Test func rendersInlineMarkupAndAttributes() throws {
        let source = "**bold** *em* ~~gone~~ `code`\n"
        let document = try render(source)
        let paragraph = try #require(document.blocks.first)
        #expect(paragraph.displayText == "bold em gone code")
        #expect(runs(paragraph, text: "bold").first?.attributes.isStrong == true)
        #expect(runs(paragraph, text: "em").first?.attributes.isEmphasis == true)
        #expect(runs(paragraph, text: "gone").first?.attributes.isStrikethrough == true)
        #expect(runs(paragraph, text: "code").first?.attributes.isCode == true)
        #expect(hiddenSource(paragraph, in: document).contains("**"))
        #expect(hiddenSource(paragraph, in: document).contains("~~"))
    }

    @Test func rendersLinksAndImages() throws {
        let source = """
        [inline](https://example.com "title") <https://swift.org> [ref]

        ![alt](img.png) ![](empty.png)

        [ref]: https://example.com/ref
        """
        let document = try render(source)
        let paragraphs = document.blocks.filter { $0.kind == .paragraph }
        #expect(paragraphs.count == 2)

        let inline = runs(paragraphs[0], text: "inline").first
        #expect(inline?.attributes.isLink == true)
        #expect(inline?.attributes.linkDestination == "https://example.com")

        let autolink = runs(paragraphs[0], text: "https://swift.org").first
        #expect(autolink?.attributes.isLink == true)

        let reference = runs(paragraphs[0], text: "ref").first
        #expect(reference?.attributes.isLink == true)
        #expect(reference?.attributes.linkDestination == "https://example.com/ref")

        let alt = runs(paragraphs[1], text: "alt").first
        #expect(alt?.attributes.isImage == true)
        #expect(alt?.attributes.linkDestination == "img.png")

        let emptyAlt = runs(paragraphs[1], text: "image").first
        #expect(emptyAlt?.role == .image)
        #expect(emptyAlt?.attributes.isImage == true)
        #expect(emptyAlt?.attributes.linkDestination == "empty.png")
    }

    @Test func decodesEntitiesAndEscapes() throws {
        let source = #"A &amp; B &#65; &hellip; \* \\"# + "\n"
        let document = try render(source)
        let paragraph = try #require(document.blocks.first)
        #expect(paragraph.displayText == "A & B A … * \\")
        #expect(hiddenSource(paragraph, in: document).isEmpty)
        #expect(paragraph.runs.contains {
            document.sourceText(in: $0.sourceRange) == "&amp;"
        })
        #expect(paragraph.runs.contains {
            document.sourceText(in: $0.sourceRange) == #"\\"#
        })
    }

    @Test func usesParserDecodingForEntitiesOutsideTheBuiltInTable() throws {
        let document = try render("half &frac12; and &Auml;.\n")
        let paragraph = try #require(document.blocks.first)
        #expect(paragraph.displayText == "half ½ and Ä.")
    }

    @Test func distinguishesSoftAndHardBreaks() throws {
        let soft = try render("one\ntwo\n")
        let softRuns = soft.blocks[0].runs.filter { $0.role == .softBreak }
        #expect(soft.blocks[0].displayText == "one two")
        #expect(softRuns.first?.displayText == " ")

        let spaced = try render("one  \ntwo\n")
        #expect(spaced.blocks[0].displayText == "one\ntwo")
        #expect(spaced.blocks[0].runs.contains { $0.role == .lineBreak })
        #expect(hiddenSource(spaced.blocks[0], in: spaced).contains("  "))

        let backslash = try render("one\\\ntwo\n")
        #expect(backslash.blocks[0].displayText == "one\ntwo")
        #expect(backslash.blocks[0].runs.contains { $0.role == .lineBreak })
        #expect(hiddenSource(backslash.blocks[0], in: backslash).contains("\\"))
        #expect(backslash.blocks[0].displayText.contains("two"))
    }

    @Test func rendersInlineHTMLWithoutInterpretingIt() throws {
        let document = try render("before <span>raw</span> after\n")
        let paragraph = try #require(document.blocks.first)
        #expect(paragraph.displayText == "before <span>raw</span> after")
        let html = runs(paragraph, text: "<span>").first
        #expect(html?.role == .html)
        #expect(html?.attributes.isHTML == true)
        #expect(runs(paragraph, text: "raw").first?.attributes.isHTML == false)
    }

    // MARK: Lists

    @Test func rendersBulletOrderedAndTaskLists() throws {
        let document = try render("""
        - [ ] todo
        - [x] done

        * a
        * b

        1. first
        2. second
        """)
        let lists = document.blocks.filter { $0.kind == .list }
        #expect(lists.count == 3)

        #expect(lists[0].displayText == "☐ todo\n☑ done\n")
        #expect(runs(lists[0], text: "☐ ").first?.attributes.listMarker == .task(checked: false))
        #expect(runs(lists[0], text: "☑ ").first?.attributes.listMarker == .task(checked: true))

        #expect(lists[1].displayText == "• a\n• b\n")
        #expect(runs(lists[1], text: "• ").first?.attributes.listMarker == .bullet)

        #expect(lists[2].displayText == "1. first\n2. second")
        #expect(runs(lists[2], text: "1. ").first?.attributes.listMarker == .ordered(1))
        #expect(runs(lists[2], text: "2. ").first?.attributes.listMarker == .ordered(2))
    }

    @Test func rendersNestedAndMultiBlockListItems() throws {
        let document = try render("""
        1. one
           1. nested
        2. two
        """)
        let list = try #require(block(document, kind: .list))
        #expect(list.displayText == "1. one\n1. nested\n2. two")

        let multi = try render("""
        - first para

          second para

        - next
        """)
        let multiList = try #require(block(multi, kind: .list))
        #expect(multiList.displayText.contains("first para"))
        #expect(multiList.displayText.contains("second para"))
        #expect(multiList.displayText.contains("next"))
    }

    // MARK: Quotes

    @Test func rendersBlockQuotesAndLazyContinuations() throws {
        let document = try render("> quote line\n> second line\n")
        let quote = try #require(block(document, kind: .blockQuote))
        #expect(quote.displayText == "quote line second line")
        #expect(quote.runs.contains { $0.displayText == "quote line" && $0.attributes.isBlockQuote })
        #expect(hiddenSource(quote, in: document).filter { $0.contains(">") }.count == 2)

        let lazy = try render("> first\ncontinued\n")
        let lazyQuote = try #require(block(lazy, kind: .blockQuote))
        #expect(lazyQuote.displayText == "first continued")
        #expect(lazyQuote.runs.contains { $0.displayText == "continued" })
    }

    // MARK: Code

    @Test func rendersFencedCodeBlocks() throws {
        let document = try render("```swift\nlet x = 1\n```\n")
        let code = try #require(block(document, kind: .codeBlock))
        #expect(code.displayText == "let x = 1\n")
        #expect(code.runs.contains { $0.attributes.codeLanguage == "swift" && $0.attributes.isCode })
        #expect(hiddenSource(code, in: document).contains("```swift\n"))
        #expect(hiddenSource(code, in: document).contains("```"))
    }

    @Test func rendersUnclosedFencesAndIndentedCode() throws {
        let unclosed = try render("```swift\nlet x = 1\n")
        #expect(block(unclosed, kind: .codeBlock)?.displayText == "let x = 1")

        let indented = try render("    let x = 1\n    let y = 2\n")
        let code = try #require(block(indented, kind: .codeBlock))
        #expect(code.displayText == "let x = 1\nlet y = 2")
        #expect(code.runs.contains { $0.role == .code && $0.attributes.isCode })
    }

    @Test func treatsAnIndentedFenceAsCodeContent() throws {
        let document = try render("    ```\n    not a fence\n    ```\n")
        let code = try #require(block(document, kind: .codeBlock))
        #expect(code.displayText == "```\nnot a fence\n```")
        #expect(code.runs.contains { $0.role == .code })

        let interior = try render("    ```\n    middle\n    ```\n    after\n")
        let interiorCode = try #require(block(interior, kind: .codeBlock))
        #expect(interiorCode.displayText == "```\nmiddle\n```\nafter")
    }

    @Test func hidesContainersAndIndentationAroundCode() throws {
        let quotedFence = try render("> ```swift\n> x\n> ```\n")
        let quoted = try #require(block(quotedFence, kind: .blockQuote))
        #expect(quoted.displayText == "x\n")

        let quotedLiteral = try render(">     ```\n>     not a fence\n>     ```\n")
        let quotedCode = try #require(block(quotedLiteral, kind: .blockQuote))
        #expect(quotedCode.displayText == "```\nnot a fence\n```")

        let listedFence = try render("- item\n\n  ```\n  x\n  ```\n")
        let listed = try #require(block(listedFence, kind: .list))
        #expect(listed.displayText == "• item\n\nx\n")

        let listedLiteral = try render("- item\n\n      ```\n      not a fence\n      ```\n")
        let listedCode = try #require(block(listedLiteral, kind: .list))
        #expect(listedCode.displayText.contains("```\nnot a fence\n```"))

        let wideFence = try render("-    ```\n     x\n     ```\n")
        let wide = try #require(block(wideFence, kind: .list))
        #expect(wide.displayText == "• x\n")

        let wideLiteral = try render("-     ```\n      not a fence\n      ```\n")
        let wideCode = try #require(block(wideLiteral, kind: .list))
        #expect(wideCode.displayText == "• ```\nnot a fence\n```")
    }

    @Test func keepsInlineCodeContentLiteral() throws {
        let document = try render("`a\nb` and `*not em*`\n")
        let paragraph = try #require(document.blocks.first)
        #expect(paragraph.displayText == "a b and *not em*")
        #expect(paragraph.runs.contains { $0.displayText == "a b" && $0.attributes.isCode })
        #expect(paragraph.runs.contains { $0.displayText == "*not em*" && $0.attributes.isCode })
    }

    // MARK: Tables

    @Test func rendersTablesWithHiddenDelimiterRows() throws {
        let document = try render("| A | B |\n|:--|--:|\n| 1 | 2 |\n")
        let table = try #require(block(document, kind: .table))
        #expect(table.displayText == "A\tB\n1\t2")
        #expect(table.runs.filter { $0.role == .tableSeparator }.count == 2)
        let hidden = hiddenSource(table, in: document)
        #expect(hidden.contains { $0.contains(":--") })
        #expect(!table.displayText.contains(":--"))
    }

    // MARK: Leaf blocks

    @Test func rendersThematicBreaksAndHTMLBlocks() throws {
        let document = try render("* * *\n\n<div>\nraw\n</div>\n")
        let thematic = try #require(block(document, kind: .thematicBreak))
        #expect(thematic.displayText == "─────\n")
        #expect(thematic.runs.first?.role == .thematicBreak)
        #expect(thematic.runs.last?.role == .lineBreak)

        let html = try #require(block(document, kind: .htmlBlock))
        #expect(html.displayText == "<div>\nraw\n</div>")
        #expect(html.runs.first?.attributes.isHTML == true)
    }

    @Test func rendersBlankBlocksAndHidesReferenceDefinitions() throws {
        let document = try render("[ref]: https://example.com\n\nUse [it][ref].\n")
        let blank = try #require(document.blocks.first)
        #expect(blank.kind == .blank)
        #expect(blank.displayText == "\n")
        #expect(blank.runs.contains {
            document.sourceText(in: $0.sourceRange).hasPrefix("[ref]:")
        })
        let paragraph = try #require(block(document, kind: .paragraph))
        #expect(paragraph.displayText == "Use it.")
    }

    @Test func rendersEmptyDocuments() throws {
        let document = try render("")
        #expect(document.blocks.isEmpty)
        #expect(document.displayText == "")
        #expect(document.sourceLength == 0)
        #expect(document.map.displayOffset(for: 0) == 0)
        #expect(document.map.sourceOffset(for: 0) == 0)

        let newline = try render("\n")
        #expect(newline.blocks.count == 1)
        #expect(newline.blocks[0].kind == .blank)
        #expect(newline.displayText == "\n")
    }

    // MARK: Offsets

    @Test func usesUTF16OffsetsForUnicode() throws {
        let source = "# Héllo 😀\n\nnaïve café\n"
        let document = try render(source)
        let heading = document.blocks[0]
        #expect(heading.displayText == "Héllo 😀")
        let text = try #require(heading.runs.first { $0.displayText == "Héllo 😀" })
        #expect(text.sourceRange == 2..<10)
        #expect(text.displayText.utf16.count == 8)
        #expect(document.sourceLength == (source as NSString).length)
    }

    @Test func usesUTF16OffsetsForCRLF() throws {
        let source = "# Title\r\n\r\nHello\r\n"
        let document = try render(source)
        #expect(document.blocks[0].displayText == "Title")
        let blank = document.blocks[1]
        #expect(blank.displayText == "\n\n")
        #expect(blank.runs.allSatisfy { $0.sourceRange.count == 2 })
        #expect(document.blocks[2].displayText == "Hello")
        #expect(document.sourceLength == (source as NSString).length)
    }

    @Test func normalizesNewlinesInsideCodeAndHTML() throws {
        let document = try render("""
        ```swift\r
        let x = 1\r
        \r
        let y = 2\r
        ```\r
        \r
        <div>\r
        raw\r
        </div>\r
        """)
        let code = try #require(block(document, kind: .codeBlock))
        #expect(code.displayText == "let x = 1\n\nlet y = 2\n")
        #expect(!code.displayText.contains("\r"))
        #expect(code.runs.contains { $0.role == .lineBreak && $0.displayText == "\n" })

        let html = try #require(block(document, kind: .htmlBlock))
        #expect(html.displayText == "<div>\nraw\n</div>")
        #expect(!html.displayText.contains("\r"))

        let indented = try render("    a\r\n    b\r\n")
        let indentedDisplay = indented.blocks
            .filter { $0.kind == .codeBlock }
            .map(\.displayText)
            .joined()
        #expect(indentedDisplay == "a\nb")
    }

    @Test func normalizesNewlinesInsideInlineHTML() throws {
        let document = try render("before <span\r\nclass=\"x\">raw</span>\r\n")
        #expect(document.displayText == "before <span\nclass=\"x\">raw</span>\n")
        #expect(!document.displayText.contains("\r"))
    }

    // MARK: Identity

    @Test func derivesStableBlockIDsFromContentAndOccurrence() throws {
        let document = try render("same\n\nsame\n\ndifferent\n")
        let paragraphs = document.blocks.filter { $0.kind == .paragraph }
        #expect(paragraphs.count == 3)
        #expect(paragraphs[0].id.occurrence == 0)
        #expect(paragraphs[1].id.occurrence == 1)
        #expect(paragraphs[0].id != paragraphs[1].id)
        #expect(paragraphs[0].id.contentHash == paragraphs[1].id.contentHash)
        #expect(paragraphs[2].id.occurrence == 0)
        #expect(paragraphs[2].id.contentHash != paragraphs[0].id.contentHash)

        let headingID = BlockID(kind: .heading, contentHash: 1, occurrence: 0)
        let paragraphID = BlockID(kind: .paragraph, contentHash: 1, occurrence: 0)
        #expect(headingID != paragraphID)
        #expect(headingID.description == "heading-1-0")
    }

    @Test func emptyHeadingIsPureSyntax() throws {
        let document = try render("#\n")
        let heading = try #require(document.blocks.first)
        #expect(heading.kind == .heading)
        #expect(heading.displayText == "")
        #expect(heading.runs.allSatisfy { $0.role == .hiddenSyntax })
    }
}
