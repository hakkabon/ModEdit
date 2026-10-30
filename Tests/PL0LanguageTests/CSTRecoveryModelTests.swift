import Testing
@testable import PL0Language

@Suite("PL/0 CST and recovery model")
struct CSTRecoveryModelTests {
    @Test func validProgramProducesAnOrderedSourceTerminalStream() {
        let result = parse("var x; x := 1.")

        #expect(result.recovery.isClean)
        #expect(result.recovery.totalCost == 0)
        #expect(result.syntaxTree.terminals.count == result.tokens.count - 1)
        #expect(result.syntaxTree.terminals.allSatisfy { $0.disposition == .source })
        #expect(result.syntaxTree.terminals.map(\.kind)
            == [.varKeyword, .identifier, .semicolon, .identifier,
                .assign, .number, .period])
    }

    @Test func insertedTerminalIsPartOfTheRecoveredConcreteStream() {
        let result = parse("var x; if x < 10 x := 1.")
        let missingThen = result.syntaxTree.missingTerminals.first {
            $0.kind == .then
        }
        let insertion = result.recovery.events.first {
            if case .insert(.then, _) = $0.action { true } else { false }
        }

        #expect(missingThen != nil)
        #expect(missingThen?.range.length == 0)
        #expect(insertion?.expected.contains(.then) == true)
        #expect(insertion?.diagnosticIDs.isEmpty == false)
        #expect(insertion?.cost == 1)
        #expect(result.recovery.insertionCount == 1)
    }

    @Test func deletedTerminalRemainsVisibleAsSkippedSyntax() {
        let result = parse("var x; begin x := 1; 123; x := 2 end.")
        let skipped = result.syntaxTree.skippedTerminals.first {
            $0.lexeme == "123"
        }
        let deletion = result.recovery.events.first {
            if case let .delete(token) = $0.action { token.lexeme == "123" }
            else { false }
        }

        #expect(skipped?.kind == .number)
        #expect(skipped?.disposition == .skipped)
        #expect(deletion?.diagnosticIDs.isEmpty == false)
        #expect(result.recovery.deletionCount >= 1)
        #expect(result.recovery.totalCost == result.recovery.events.count)
    }

    @Test func compatibilityViewsComeFromTheFirstClassModels() {
        let result = parse("if odd 1 call p.")

        #expect(result.root == result.syntaxTree.root)
        #expect(result.recoveryActions == result.recovery.actions)
        #expect(result.expectations == result.recovery.expectations)
        #expect(result.syntaxTree.outline().contains("Terminals"))
        #expect(result.syntaxTree.outline().contains("[missing]"))
    }

    @Test func grammaticalParentsContainTheirChildrenAndTerminals() {
        let result = parse("var x; begin x := 1 + 2; if odd x then x := x - 1 end.")
        let assignments = nodes(kind: "Assignment", in: result.root)

        #expect(rangesAreNested(result.root))
        #expect(assignments.count == 2)
        #expect(result.syntaxTree.terminals(in: assignments[0]).map(\.lexeme)
            == ["x", ":=", "1", "+", "2"])
    }

    private func parse(_ source: String) -> ParseResult {
        PL0Frontend().parse(SourceSnapshot(version: 1, text: source))
    }

    private func rangesAreNested(_ node: SyntaxNode) -> Bool {
        node.children.allSatisfy { child in
            child.range.location >= node.range.location
                && child.range.end <= node.range.end
                && rangesAreNested(child)
        }
    }

    private func nodes(kind: String, in root: SyntaxNode) -> [SyntaxNode] {
        var result = root.kind == kind ? [root] : []
        for child in root.children {
            result.append(contentsOf: nodes(kind: kind, in: child))
        }
        return result
    }
}
