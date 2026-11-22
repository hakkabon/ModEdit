import Foundation
import Testing
@testable import RenderedText

@Suite("Source display map")
struct SourceDisplayMapTests {
    private func makeMap(source: String,
                         runs: [(Range<Int>, String, RenderedRunRole)]) throws -> SourceDisplayMap {
        let block = RenderedBlock(
            id: BlockID(kind: .paragraph, contentHash: StableHash.fnv1a(source), occurrence: 0),
            kind: .paragraph,
            sourceRange: 0..<source.utf16.count,
            runs: runs.map {
                RenderedRun(sourceRange: $0.0, displayText: $0.1, role: $0.2)
            })
        return try RenderedDocument(source: source, blocks: [block]).map
    }

    @Test func identityRunsMapOneToOne() throws {
        let map = try makeMap(source: "abcd", runs: [(0..<4, "abcd", .text)])
        #expect(map.sourceLength == 4)
        #expect(map.displayLength == 4)
        for offset in 0...4 {
            #expect(map.displayOffset(for: offset, affinity: .leading) == offset)
            #expect(map.displayOffset(for: offset, affinity: .trailing) == offset)
            #expect(map.sourceOffset(for: offset, affinity: .leading) == offset)
            #expect(map.sourceOffset(for: offset, affinity: .trailing) == offset)
        }
        #expect(map.displayRange(forSource: 1..<3) == 1..<3)
        #expect(map.sourceRange(forDisplay: 1..<3) == 1..<3)
        #expect(!map.isHiddenSourceOffset(1))
    }

    @Test func hiddenMarkupHasZeroDisplayWidth() throws {
        let map = try makeMap(
            source: "**a**b",
            runs: [
                (0..<2, "", .hiddenSyntax),
                (2..<3, "a", .text),
                (3..<5, "", .hiddenSyntax),
                (5..<6, "b", .text),
            ])
        #expect(map.displayLength == 2)

        #expect(map.displayOffset(for: 0, affinity: .leading) == 0)
        #expect(map.displayOffset(for: 0, affinity: .trailing) == 0)
        #expect(map.displayOffset(for: 1, affinity: .trailing) == 0)
        #expect(map.displayOffset(for: 2, affinity: .trailing) == 0)
        #expect(map.displayOffset(for: 3, affinity: .leading) == 1)
        #expect(map.displayOffset(for: 3, affinity: .trailing) == 1)
        #expect(map.displayOffset(for: 5, affinity: .trailing) == 1)
        #expect(map.displayOffset(for: 6, affinity: .trailing) == 2)

        #expect(map.sourceOffset(for: 0, affinity: .leading) == 0)
        #expect(map.sourceOffset(for: 0, affinity: .trailing) == 2)
        #expect(map.sourceOffset(for: 1, affinity: .leading) == 3)
        #expect(map.sourceOffset(for: 1, affinity: .trailing) == 5)
        #expect(map.sourceOffset(for: 2, affinity: .leading) == 6)
        #expect(map.sourceOffset(for: 2, affinity: .trailing) == 6)

        #expect(map.isHiddenSourceOffset(0))
        #expect(map.isHiddenSourceOffset(1))
        #expect(!map.isHiddenSourceOffset(2))
        #expect(map.isHiddenSourceOffset(3))
        #expect(map.isHiddenSourceOffset(4))
        #expect(!map.isHiddenSourceOffset(5))
        #expect(!map.isHiddenSourceOffset(6))
    }

    @Test func hiddenMarkupRangeMappingHonorsAffinity() throws {
        let map = try makeMap(
            source: "**a**b",
            runs: [
                (0..<2, "", .hiddenSyntax),
                (2..<3, "a", .text),
                (3..<5, "", .hiddenSyntax),
                (5..<6, "b", .text),
            ])
        #expect(map.displayRange(forSource: 0..<2, affinity: .leading) == 0..<0)
        #expect(map.displayRange(forSource: 0..<2, affinity: .trailing) == 0..<0)
        #expect(map.displayRange(forSource: 2..<3) == 0..<1)
        #expect(map.displayRange(forSource: 5..<6) == 1..<2)

        #expect(map.sourceRange(forDisplay: 0..<1, affinity: .leading) == 0..<3)
        #expect(map.sourceRange(forDisplay: 0..<1, affinity: .trailing) == 2..<5)
        #expect(map.sourceRange(forDisplay: 1..<2, affinity: .leading) == 3..<6)
        #expect(map.sourceRange(forDisplay: 1..<2, affinity: .trailing) == 5..<6)
    }

    @Test func substitutionRunsMapProportionallyAndRoundTrip() throws {
        // Six source code units (including backticks) project to four.
        let map = try makeMap(source: "`code`", runs: [(0..<6, "code", .code)])
        #expect(map.sourceLength == 6)
        #expect(map.displayLength == 4)

        #expect(map.displayOffset(for: 0, affinity: .trailing) == 0)
        #expect(map.displayOffset(for: 1, affinity: .leading) == 0)
        #expect(map.displayOffset(for: 1, affinity: .trailing) == 1)
        #expect(map.displayOffset(for: 2, affinity: .leading) == 1)
        #expect(map.displayOffset(for: 2, affinity: .trailing) == 2)
        #expect(map.displayOffset(for: 3, affinity: .trailing) == 2)
        #expect(map.displayOffset(for: 5, affinity: .leading) == 3)
        #expect(map.displayOffset(for: 5, affinity: .trailing) == 4)
        #expect(map.displayOffset(for: 6, affinity: .trailing) == 4)

        #expect(map.sourceOffset(for: 1, affinity: .leading) == 2)
        #expect(map.sourceOffset(for: 1, affinity: .trailing) == 1)
        #expect(map.sourceOffset(for: 2, affinity: .leading) == 3)
        #expect(map.sourceOffset(for: 2, affinity: .trailing) == 3)
        #expect(map.sourceOffset(for: 3, affinity: .leading) == 5)
        #expect(map.sourceOffset(for: 3, affinity: .trailing) == 4)
        #expect(map.sourceOffset(for: 4, affinity: .leading) == 6)
        #expect(map.sourceOffset(for: 4, affinity: .trailing) == 6)

        for display in 0...4 {
            for affinity in TextAffinity.allCases {
                let source = map.sourceOffset(for: display, affinity: affinity)
                #expect(map.displayOffset(for: source, affinity: affinity) == display)
            }
        }
    }

    @Test func entitySubstitutionRoundTripsEveryDisplayOffset() throws {
        let map = try makeMap(source: "&amp;", runs: [(0..<5, "&", .text)])
        #expect(map.displayLength == 1)
        #expect(map.displayOffset(for: 0, affinity: .leading) == 0)
        #expect(map.displayOffset(for: 0, affinity: .trailing) == 0)
        #expect(map.displayOffset(for: 4, affinity: .leading) == 0)
        #expect(map.displayOffset(for: 4, affinity: .trailing) == 1)
        #expect(map.displayOffset(for: 5, affinity: .trailing) == 1)

        #expect(map.sourceOffset(for: 0, affinity: .leading) == 0)
        #expect(map.sourceOffset(for: 0, affinity: .trailing) == 0)
        #expect(map.sourceOffset(for: 1, affinity: .leading) == 5)
        #expect(map.sourceOffset(for: 1, affinity: .trailing) == 5)
    }

    @Test func everyDisplayOffsetRoundTripsForArbitraryRuns() throws {
        let cases: [(String, [(Range<Int>, String, RenderedRunRole)])] = [
            ("abcd", [(0..<4, "abcd", .text)]),
            ("**a**b", [
                (0..<2, "", .hiddenSyntax),
                (2..<3, "a", .text),
                (3..<5, "", .hiddenSyntax),
                (5..<6, "b", .text),
            ]),
            ("`code`", [(0..<6, "code", .code)]),
            ("&amp;&lt;", [(0..<9, "&<", .text)]),
            ("\r\n", [(0..<2, "\n", .lineBreak)]),
            ("***", [(0..<3, "───", .thematicBreak)]),
        ]

        for (source, runs) in cases {
            let map = try makeMap(source: source, runs: runs)
            for affinity in TextAffinity.allCases {
                for display in 0...map.displayLength {
                    let sourceOffset = map.sourceOffset(for: display, affinity: affinity)
                    #expect(sourceOffset >= 0)
                    #expect(sourceOffset <= map.sourceLength)
                    #expect(
                        map.displayOffset(for: sourceOffset, affinity: affinity) == display,
                        "\(source.debugDescription) display \(display) \(affinity)")
                }
                for offset in 0...map.sourceLength {
                    let display = try #require(
                        map.displayOffset(for: offset, affinity: affinity),
                        "\(source.debugDescription) source \(offset) \(affinity)")
                    let sourceOffset = map.sourceOffset(for: display, affinity: affinity)
                    #expect(
                        map.displayOffset(for: sourceOffset, affinity: affinity) == display,
                        "\(source.debugDescription) source \(offset) \(affinity)")
                }
            }
        }
    }

    @Test func mappingIsMonotonic() throws {
        let map = try makeMap(
            source: "a**b**c*&amp;*",
            runs: [
                (0..<1, "a", .text),
                (1..<3, "", .hiddenSyntax),
                (3..<4, "b", .text),
                (4..<6, "", .hiddenSyntax),
                (6..<7, "c", .text),
                (7..<8, "", .hiddenSyntax),
                (8..<13, "&", .text),
                (13..<14, "", .hiddenSyntax),
            ])
        for affinity in TextAffinity.allCases {
            var previousDisplay = -1
            for offset in 0...map.sourceLength {
                let display = try #require(map.displayOffset(for: offset, affinity: affinity))
                #expect(display >= previousDisplay)
                previousDisplay = display
            }
            var previousSource = -1
            for display in 0...map.displayLength {
                let source = map.sourceOffset(for: display, affinity: affinity)
                #expect(source >= previousSource)
                previousSource = source
            }
        }
    }

    @Test func outOfRangeInputsClampOrReturnNil() throws {
        let map = try makeMap(source: "ab", runs: [(0..<2, "ab", .text)])
        #expect(map.displayOffset(for: -1) == nil)
        #expect(map.displayOffset(for: 3) == nil)
        #expect(map.sourceOffset(for: -1) == 0)
        #expect(map.sourceOffset(for: 3) == 2)
        #expect(map.displayRange(forSource: -1..<1) == nil)
        #expect(map.displayRange(forSource: 0..<3) == nil)
        #expect(map.sourceRange(forDisplay: -1..<1) == nil)
        #expect(map.sourceRange(forDisplay: 0..<3) == nil)
    }

    @Test func emptyMapsCollapseToZero() throws {
        let document = try RenderedDocument(source: "", blocks: [])
        #expect(document.map.sourceLength == 0)
        #expect(document.map.displayLength == 0)
        #expect(document.map.displayOffset(for: 0) == 0)
        #expect(document.map.sourceOffset(for: 0) == 0)
        #expect(document.map.displayRange(forSource: 0..<0) == 0..<0)
        #expect(document.map.sourceRange(forDisplay: 0..<0) == 0..<0)
        #expect(!document.map.isHiddenSourceOffset(0))
    }
}
