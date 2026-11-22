import Foundation
import Testing
@testable import RenderedText

private let projectionCorpus: [String] = [
    "",
    "\n",
    "\n\n\n",
    "plain text",
    "plain text\n",
    "# Heading\n\nParagraph.\n",
    "One\n===\n\nTwo\n---\n\nThree\n",
    "# Héllo 😀\n\nnaïve café\n",
    #"""
    # Heading *em* **strong** ~~strike~~ `code`

    Paragraph with [link](https://example.com "title"), <https://swift.org>,
    ![alt](img.png), &amp; &#65; &hellip; \* and a hard break.  
    Second line with backslash\
    third line.
    """#,
    #"""
    - [ ] todo
    - [x] done
      - nested *item*

    1. first
    2. second

    * bullet
    * bullet
    """#,
    #"""
    > quote line
    > second line
    >
    > - item
    > - item

    Lazy
    continuation
    """#,
    #"""
    ```swift
    let x = 1
    let y = 2
    ```

        indented code
        second line
    """#,
    #"""
    | A | B |
    |:--|--:|
    | 1 | 2 |
    | **x** | `y` |
    """#,
    #"""
    ---

    <div>
    raw html
    </div>

    Inline <span>html</span> after.
    """#,
    #"""
    Reference [ref] and [text][ref].

    [ref]: https://example.com
    """#,
    "![alt](img.png) ![](empty.png)\n",
    "Autolink <https://example.com> and <a@b.com>\n",
    "# Title\r\n\r\nHello\r\n\r\n- item\r\n",
    "```swift\r\nlet x = 1\r\n```\r\n\r\n<div>\r\nraw\r\n</div>\r\n",
    "before <span\r\nclass=\"x\">raw</span>\r\n",
    "half &frac12; and &Auml;.\n",
    "same\n\nsame\n\nsame\n",
    "#\n\n#\n",
    "***\n\n---\n\n___\n",
    "[]()\n\n![](x)\n\n[ref]: /x\n",
    "a\tb\nc\td\n",
    #"""
    - first paragraph

      second paragraph

      > nested quote

    - next
    """#,
    #"""
    Setext with *em*
    ===============

    > ## Quoted heading
    >
    > 1. one
    > 2. two
    """#,
    #"""
    > ```swift
    > let x = 1
    > ```

    - item

          ```
          not a fence
          ```
    """#,
    #"""
    -    ```swift
         let x = 1
         ```

    >    ```swift
    >    let y = 2
    >    ```
    """#,
]

@Suite("Projection corpus")
struct ProjectionCorpusTests {
    @Test(arguments: projectionCorpus)
    func everyDisplayOffsetRoundTripsToItself(source: String) throws {
        let document = try MarkdownRenderer().render(source)
        for affinity in TextAffinity.allCases {
            for display in 0...document.displayLength {
                let sourceOffset = document.map.sourceOffset(
                    for: display,
                    affinity: affinity)
                #expect(sourceOffset >= 0)
                #expect(sourceOffset <= document.sourceLength)
                let roundTripped = document.map.displayOffset(
                    for: sourceOffset,
                    affinity: affinity)
                #expect(
                    roundTripped == display,
                    "display \(display) \(affinity) in \(source.debugDescription)")
            }
        }
    }

    @Test(arguments: projectionCorpus)
    func everySourceOffsetProjectsStably(source: String) throws {
        let document = try MarkdownRenderer().render(source)
        for affinity in TextAffinity.allCases {
            for offset in 0...document.sourceLength {
                let display = try #require(
                    document.map.displayOffset(for: offset, affinity: affinity),
                    "source \(offset) \(affinity)")
                #expect(display >= 0)
                #expect(display <= document.displayLength)
                let sourceOffset = document.map.sourceOffset(
                    for: display,
                    affinity: affinity)
                let roundTripped = document.map.displayOffset(
                    for: sourceOffset,
                    affinity: affinity)
                #expect(
                    roundTripped == display,
                    "source \(offset) -> display \(display) \(affinity) in \(source.debugDescription)")
            }
        }
    }

    @Test(arguments: projectionCorpus)
    func mappingIsMonotonicInBothDirections(source: String) throws {
        let document = try MarkdownRenderer().render(source)
        for affinity in TextAffinity.allCases {
            var previousDisplay = -1
            for offset in 0...document.sourceLength {
                let display = try #require(
                    document.map.displayOffset(for: offset, affinity: affinity))
                #expect(display >= previousDisplay)
                previousDisplay = display
            }

            var previousSource = -1
            for display in 0...document.displayLength {
                let offset = document.map.sourceOffset(for: display, affinity: affinity)
                #expect(offset >= previousSource)
                previousSource = offset
            }
        }
    }

    @Test(arguments: projectionCorpus)
    func blocksAndRunsTileTheSource(source: String) throws {
        let document = try MarkdownRenderer().render(source)
        var blockCursor = 0
        for block in document.blocks {
            #expect(block.sourceRange.lowerBound == blockCursor)
            #expect(!block.sourceRange.isEmpty)
            var runCursor = block.sourceRange.lowerBound
            for run in block.runs {
                #expect(run.sourceRange.lowerBound == runCursor)
                #expect(!run.sourceRange.isEmpty)
                #expect(run.sourceRange.upperBound <= block.sourceRange.upperBound)
                runCursor = run.sourceRange.upperBound
            }
            #expect(runCursor == block.sourceRange.upperBound)
            #expect(block.displayText == block.runs.map(\.displayText).joined())
            #expect(block.sourceRange.count == block.runs.reduce(0) {
                $0 + $1.sourceRange.count
            })
            blockCursor = block.sourceRange.upperBound
        }
        #expect(blockCursor == document.sourceLength)
        #expect(document.displayText == document.blocks.map(\.displayText).joined())
    }

    @Test(arguments: projectionCorpus)
    func rangeMappingsStayInBounds(source: String) throws {
        let document = try MarkdownRenderer().render(source)
        for affinity in TextAffinity.allCases {
            let wholeDisplay = try #require(document.map.displayRange(
                forSource: 0..<document.sourceLength,
                affinity: affinity))
            #expect(wholeDisplay.lowerBound >= 0)
            #expect(wholeDisplay.upperBound <= document.displayLength)

            let wholeSource = try #require(document.map.sourceRange(
                forDisplay: 0..<document.displayLength,
                affinity: affinity))
            #expect(wholeSource.lowerBound >= 0)
            #expect(wholeSource.upperBound <= document.sourceLength)

            for block in document.blocks {
                let display = try #require(document.map.displayRange(
                    forSource: block.sourceRange,
                    affinity: affinity))
                #expect(display.lowerBound <= display.upperBound)
                #expect(display.lowerBound >= 0)
                #expect(display.upperBound <= document.displayLength)

                let lower = try #require(document.map.displayOffset(
                    for: block.sourceRange.lowerBound,
                    affinity: affinity))
                let upper = try #require(document.map.displayOffset(
                    for: block.sourceRange.upperBound,
                    affinity: affinity))
                #expect(lower <= upper)
                #expect(
                    document.map.displayOffset(
                        for: document.map.sourceOffset(for: display.lowerBound, affinity: affinity),
                        affinity: affinity) == display.lowerBound)
            }
        }
    }

    @Test(arguments: projectionCorpus)
    func blockBoundariesHaveCaretsOnBothSides(source: String) throws {
        let document = try MarkdownRenderer().render(source)
        for block in document.blocks {
            for boundary in [block.sourceRange.lowerBound, block.sourceRange.upperBound] {
                for affinity in TextAffinity.allCases {
                    let display = try #require(document.map.displayOffset(
                        for: boundary,
                        affinity: affinity))
                    let sourceOffset = document.map.sourceOffset(
                        for: display,
                        affinity: affinity)
                    let roundTripped = document.map.displayOffset(
                        for: sourceOffset,
                        affinity: affinity)
                    #expect(roundTripped == display)
                }
            }
        }
    }

    @Test(arguments: projectionCorpus)
    func blockIDsAreUniqueAndStable(source: String) throws {
        let document = try MarkdownRenderer().render(source)
        #expect(Set(document.blocks.map(\.id)).count == document.blocks.count)

        let again = try MarkdownRenderer().render(source)
        #expect(document.blocks.map(\.id) == again.blocks.map(\.id))
        #expect(document.blocks.map(\.sourceRange) == again.blocks.map(\.sourceRange))
    }
}
