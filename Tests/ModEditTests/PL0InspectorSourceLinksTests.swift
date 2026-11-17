import Foundation
import PL0Language
import Testing
@testable import ModEditCore

@Test func inspectorLinksSourceTokensAndRecoveredTerminals() throws {
    let source = "var x; begin x := 1 end"
    let parse = PL0Frontend().parse(SourceSnapshot(version: 1, text: source))
    let links = PL0InspectorSourceLinks(parse)
    let assignment = try #require(links.nodes.first { $0.label == "Assignment" })
    let token = try #require(links.tokens.first {
        $0.range.location == assignment.range.location
    })
    let terminal = try #require(links.terminals.first {
        $0.range == token.range
    })
    let caret = NSRange(location: token.range.location, length: 0)
    let fromSource = links.highlight(selection: caret, explicit: nil)
    #expect(fromSource.tokenIDs == [token.id])
    #expect(fromSource.syntaxIDs.contains(terminal.id))
    let fromToken = links.highlight(selection: caret, explicit: token)
    #expect(fromToken.syntaxAnchor == terminal.id)
    let fromNode = links.highlight(selection: caret, explicit: assignment)
    #expect(fromNode.syntaxAnchor == assignment.id)
    #expect(fromNode.tokenIDs.count == 3)

    let trivia = links.highlight(selection: NSRange(location: 3, length: 0), explicit: nil)
    #expect(trivia.tokenIDs.isEmpty)
    #expect(trivia.syntaxIDs.isEmpty)

    let missing = try #require(links.terminals.first { $0.label.hasSuffix("[missing]") })
    #expect(missing.range.length == 0)
    let fromMissing = links.highlight(selection: caret, explicit: missing)
    #expect(fromMissing.syntaxAnchor == missing.id)
    #expect(fromMissing.tokenIDs.isEmpty)
}
