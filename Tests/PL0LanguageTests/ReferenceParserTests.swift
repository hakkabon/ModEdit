import Testing
@testable import PL0Language

@Suite("PL/0 reference parser")
struct ReferenceParserTests {
    @Test func publishesItsRoleAndCapabilities() {
        let descriptor = ReferencePL0Parser().descriptor

        #expect(descriptor.id == "reference-ll")
        #expect(descriptor.capabilities.contains(.deterministicTree))
        #expect(descriptor.capabilities.contains(.errorRecovery))
        #expect(descriptor.capabilities.contains(.expectedTokens))
        #expect(descriptor.capabilities.contains(.incremental))
        #expect(!descriptor.capabilities.contains(.ambiguity))
    }

    @Test(arguments: [
        ".",
        "const a = 1, b = 2; .",
        "var x, y; x := -1 + 2 * (3 + y).",
        "procedure p; call p; call p.",
        "begin call p; if odd x then x := x + 1; while x # 0 do x := x - 1 end.",
        "begin if x <= 10 then x := 1; if x >= 2 then x := 0 end.",
    ])
    func acceptsControlledGrammarCorpus(source: String) {
        let result = PL0Frontend().parse(SourceSnapshot(version: 1, text: source))

        #expect(result.diagnostics.isEmpty, "\(source): \(result.diagnostics)")
        #expect(result.recoveryActions.isEmpty)
        #expect(result.root.kind == "Program")
    }

    @Test func missingTokenDiagnosticPublishesExpectedTerminal() {
        let source = "var x; if x < 10 x := 1."
        let result = PL0Frontend().parse(SourceSnapshot(version: 1, text: source))
        let diagnostic = result.diagnostics.first { $0.expected.contains(.then) }

        #expect(diagnostic != nil)
        #expect(result.expectations.contains {
            $0.offset == diagnostic?.range.location && $0.kinds == [.then]
        })
    }

    @Test func panicRecoveryPreservesStatementAfterGarbage() {
        let source = "var x; begin x := 1; 123; x := 2 end."
        let result = PL0Frontend().parse(SourceSnapshot(version: 1, text: source))

        #expect(result.diagnostics.contains { $0.message == "Expected a statement" })
        #expect(result.recoveryActions.contains {
            if case .delete(let token) = $0 { token.lexeme == "123" } else { false }
        })
        #expect(result.root.outline().components(separatedBy: "Assignment").count - 1 == 2)
    }

    @Test func expressionRecoveryConsumesGarbageAndKeepsFollowingFactor() {
        let source = "var x; x := @ 1."
        let result = PL0Frontend().parse(SourceSnapshot(version: 1, text: source))

        #expect(result.root.outline().contains("RecoveredFactor"))
        #expect(result.root.outline().contains("Number"))
        #expect(result.recoveryActions.contains {
            if case .delete(let token) = $0 { token.lexeme == "@" } else { false }
        })
    }

    @Test func directParserAndFrontendProduceSameSyntaxResult() {
        let snapshot = SourceSnapshot(version: 9, text: "var x; begin x := 1 end.")
        let lexed = PL0Lexer().tokenize(snapshot)
        let direct = ReferencePL0Parser().parse(
            ParserInput(tokens: lexed.tokens, lexicalDiagnostics: lexed.diagnostics))
        let frontend = PL0Frontend().parse(snapshot)

        #expect(direct.root == frontend.root)
        #expect(direct.diagnostics == frontend.diagnostics)
        #expect(direct.recoveryActions == frontend.recoveryActions)
        #expect(direct.expectations == frontend.expectations)
        #expect(frontend.parser == ReferencePL0Parser().descriptor)
    }

    @Test func directParserNormalizesMissingEndOfFileToken() {
        let output = ReferencePL0Parser().parse(
            ParserInput(tokens: [], lexicalDiagnostics: []))

        #expect(output.root.kind == "Program")
        #expect(output.diagnostics.contains { $0.expected.contains(.period) })
    }

    @Test func malformedInputAlwaysTerminatesWithAProgramTree() {
        let fragments = ["@", "begin", "const", "(", ")", ";", "if then", "/*", "123", ":="]
        for first in fragments {
            for second in fragments {
                let result = PL0Frontend().parse(SourceSnapshot(
                    version: 1, text: first + " " + second))
                #expect(result.root.kind == "Program")
                #expect(result.recoveryActions.count <= result.tokens.count * 4 + 4)
            }
        }
    }
}
