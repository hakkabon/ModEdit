import AppKit
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
    #expect(fromSource.syntaxAnchor?.hasPrefix("node:") == true)
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

@MainActor
@Test func inspectorLinksFollowTextViewSelectionAfterReveal() throws {
    let source = "var x; begin x := 1 end."
    let document = EditorDocument()
    document.setText(source)
    let model = EditorModel(document: document)
    let coordinator = EditorTextView.Coordinator(model: model)
    let textView = EditorNSTextView(frame: .zero)
    textView.string = source
    coordinator.attach(to: textView)

    let parse = PL0Frontend().parse(SourceSnapshot(version: 1, text: source))
    let links = PL0InspectorSourceLinks(parse)
    let assignment = try #require(links.nodes.first { $0.label == "Assignment" })
    model.revealSourceRange(assignment.range)
    coordinator.fulfillRevealRequest()

    let assignmentSelection = NSRange(location: assignment.range.location,
                                      length: assignment.range.length)
    #expect(textView.selectedRange() == assignmentSelection)
    #expect(model.selection == assignmentSelection)
    #expect(links.highlight(selection: model.selection, explicit: assignment).tokenIDs.count == 3)

    let number = try #require(links.tokens.first { $0.range.end == assignment.range.end })
    let caret = NSRange(location: number.range.location, length: 0)
    textView.setSelectedRange(caret)
    #expect(model.selection == caret)
    #expect(links.highlight(selection: model.selection, explicit: nil).tokenIDs == [number.id])
}
