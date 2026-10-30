import Foundation
import Testing
@testable import PL0Language

@Suite("PL/0 parser reuse")
struct ParserReuseTests {
    @Test func localExpressionEditReusesSurroundingStatements() async throws {
        let original = "begin a := 1; b := 2; c := 3 end."
        let session = PL0LanguageSession()
        let first = await session.parse(SourceSnapshot(version: 1, text: original))
        let range = (original as NSString).range(of: "2")
        let changed = (original as NSString).replacingCharacters(in: range, with: "200")
        let second = await session.parse(SourceSnapshot(
            version: 2, text: changed,
            edit: SourceEdit(baseVersion: 1,
                             replacedRange: SourceRange(location: range.location,
                                                        length: range.length),
                             replacementLength: 3)))
        let full = PL0Frontend().parse(SourceSnapshot(version: 2, text: changed))

        #expect(!first.metrics.incrementalParsing.incremental)
        #expect(second.metrics.incrementalParsing.incremental)
        #expect(second.metrics.incrementalParsing.reusedNodeCount > 0)
        #expect(second.metrics.incrementalParsing.reusedTokenCount >= 6)
        expectEquivalent(second, full)

        let firstAssignments = nodes(kind: "Assignment", in: first.root)
        let secondAssignments = nodes(kind: "Assignment", in: second.root)
        #expect(firstAssignments.count == 3)
        #expect(secondAssignments.count == 3)
        #expect(firstAssignments[0].id == secondAssignments[0].id)
        #expect(firstAssignments[1].id != secondAssignments[1].id)
        #expect(firstAssignments[2].id == secondAssignments[2].id)
        #expect(secondAssignments[2].range.location == firstAssignments[2].range.location + 2)
    }

    @Test func insertionBeforeStatementRelocatesAndReusesItsTree() async throws {
        let original = "begin x := 1; y := 2 end."
        let session = PL0LanguageSession()
        let first = await session.parse(SourceSnapshot(version: 1, text: original))
        let insertion = (original as NSString).range(of: "x := 1").location
        let added = "z := 0; "
        let changed = (original as NSString).replacingCharacters(
            in: NSRange(location: insertion, length: 0), with: added)
        let second = await session.parse(SourceSnapshot(
            version: 2, text: changed,
            edit: SourceEdit(baseVersion: 1,
                             replacedRange: SourceRange(location: insertion, length: 0),
                             replacementLength: (added as NSString).length)))

        let oldAssignments = nodes(kind: "Assignment", in: first.root)
        let newAssignments = nodes(kind: "Assignment", in: second.root)
        #expect(newAssignments.count == 3)
        #expect(oldAssignments[0].id == newAssignments[1].id)
        #expect(oldAssignments[1].id == newAssignments[2].id)
        #expect(newAssignments[1].range.location
                == oldAssignments[0].range.location + (added as NSString).length)
        #expect(second.metrics.incrementalParsing.reusedNodeCount > 0)
    }

    @Test func skippedTokenizerVersionSafelyDisablesParserReuse() async {
        let session = PL0LanguageSession()
        _ = await session.parse(SourceSnapshot(version: 1,
                                                text: "begin x := 1 end."))
        let result = await session.parse(SourceSnapshot(
            version: 3, text: "begin y := 2 end.",
            edit: SourceEdit(baseVersion: 2,
                             replacedRange: SourceRange(location: 6, length: 1),
                             replacementLength: 1)))

        #expect(!result.metrics.incrementalLexing.incremental)
        #expect(!result.metrics.incrementalParsing.incremental)
        #expect(result.metrics.incrementalParsing.reusedNodeCount == 0)
    }

    @Test func repeatedEditsRemainEquivalentToFullReferenceParse() async {
        var text = "begin a := 1; b := 2; c := 3; d := 4 end."
        var version: UInt64 = 1
        let session = PL0LanguageSession()
        _ = await session.parse(SourceSnapshot(version: version, text: text))
        let edits = [("1", "10"), ("3", "30"), ("b := 2", "b := a + 2"),
                     ("d := 4", "while d > 0 do d := d - 1")]

        for (needle, replacement) in edits {
            let range = (text as NSString).range(of: needle)
            let next = (text as NSString).replacingCharacters(in: range, with: replacement)
            let oldVersion = version
            version += 1
            let incremental = await session.parse(SourceSnapshot(
                version: version, text: next,
                edit: SourceEdit(baseVersion: oldVersion,
                                 replacedRange: SourceRange(location: range.location,
                                                            length: range.length),
                                 replacementLength: (replacement as NSString).length)))
            let full = PL0Frontend().parse(SourceSnapshot(version: version, text: next))
            expectEquivalent(incremental, full)
            text = next
        }
    }

    @Test func outerReuseRetainsFineGrainedEntriesForTheFollowingEdit() async {
        let original = "// header\nbegin a := 1; b := 2; c := 3 end."
        let session = PL0LanguageSession()
        let first = await session.parse(SourceSnapshot(version: 1, text: original))

        let whitespaceLocation = (original as NSString).range(of: "header").location
        let withWhitespace = (original as NSString).replacingCharacters(
            in: NSRange(location: whitespaceLocation, length: 0), with: " ")
        let outerReuse = await session.parse(SourceSnapshot(
            version: 2, text: withWhitespace,
            edit: SourceEdit(baseVersion: 1,
                             replacedRange: SourceRange(location: whitespaceLocation, length: 0),
                             replacementLength: 1)))
        #expect(outerReuse.metrics.incrementalParsing.reusedNodeCount
                == first.root.children[0].nodeCount)

        let middle = (withWhitespace as NSString).range(of: "2")
        let changed = (withWhitespace as NSString).replacingCharacters(in: middle, with: "20")
        let fineReuse = await session.parse(SourceSnapshot(
            version: 3, text: changed,
            edit: SourceEdit(baseVersion: 2,
                             replacedRange: SourceRange(location: middle.location,
                                                        length: middle.length),
                             replacementLength: 2)))
        let full = PL0Frontend().parse(SourceSnapshot(version: 3, text: changed))
        expectEquivalent(fineReuse, full)
        #expect(fineReuse.metrics.incrementalParsing.reusedNodeCount > 0)

        let beforeAssignments = nodes(kind: "Assignment", in: outerReuse.root)
        let afterAssignments = nodes(kind: "Assignment", in: fineReuse.root)
        #expect(beforeAssignments[0].id == afterAssignments[0].id)
        #expect(beforeAssignments[1].id != afterAssignments[1].id)
        #expect(beforeAssignments[2].id == afterAssignments[2].id)
    }

    private func expectEquivalent(_ incremental: ParseResult, _ full: ParseResult) {
        #expect(incremental.syntaxTree == full.syntaxTree)
        #expect(incremental.root.outline() == full.root.outline())
        #expect(incremental.diagnostics == full.diagnostics)
        #expect(incremental.recoveryActions == full.recoveryActions)
        #expect(incremental.expectations == full.expectations)
    }

    private func nodes(kind: String, in root: SyntaxNode) -> [SyntaxNode] {
        var result = root.kind == kind ? [root] : []
        for child in root.children { result.append(contentsOf: nodes(kind: kind, in: child)) }
        return result
    }
}
