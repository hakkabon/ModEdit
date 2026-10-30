import Foundation
import Testing
@testable import PL0Language

@Suite("PL/0 reference language")
struct PL0LanguageTests {
    @Test func tokenizesClassicProgramWithLocations() {
        let source = "const limit = 10;\nvar x;\nbegin x := limit end."
        let result = PL0Lexer().tokenize(SourceSnapshot(version: 1, text: source))

        #expect(result.diagnostics.isEmpty)
        #expect(result.tokens.map(\.kind).starts(with: [.const, .identifier, .equal, .number]))
        #expect(result.tokens.first?.location == SourceLocation(offset: 0, line: 1, column: 1))
        #expect(result.tokens.last?.kind == .endOfFile)
    }

    @Test func parsesCompletePL0Program() {
        let source = """
        const limit = 10;
        var x;
        procedure increment;
        begin x := x + 1 end;
        begin
          x := 0;
          while x < limit do call increment
        end.
        """
        let result = PL0Frontend().parse(SourceSnapshot(version: 42, text: source))

        #expect(result.version == 42)
        #expect(result.diagnostics.isEmpty)
        #expect(result.recoveryActions.isEmpty)
        #expect(result.root.kind == "Program")
        #expect(result.root.outline().contains("WhileStatement"))
    }

    @Test func missingThenIsRetainedAsExplicitRecovery() {
        let result = PL0Frontend().parse(SourceSnapshot(
            version: 2, text: "var x; if x < 10 x := x + 1."))

        #expect(result.diagnostics.contains { $0.message.contains("then") })
        #expect(result.recoveryActions.contains {
            if case .insert(.then, _) = $0 { true } else { false }
        })
        #expect(result.root.outline().contains("IfStatement"))
    }

    @Test func missingClosingTokensDoNotPreventTreeConstruction() {
        let result = PL0Frontend().parse(SourceSnapshot(
            version: 3, text: "begin if odd 1 then begin call p"))

        #expect(!result.diagnostics.isEmpty)
        #expect(result.recoveryActions.count >= 3)
        #expect(result.root.kind == "Program")
    }

    @Test func malformedCharacterIsDeletedAndParsingTerminates() {
        let result = PL0Frontend().parse(SourceSnapshot(version: 4, text: "@."))

        #expect(result.diagnostics.contains { $0.message.contains("Unexpected character") })
        #expect(result.recoveryActions.contains {
            if case .delete(let token) = $0 { token.lexeme == "@" } else { false }
        })
    }

    @Test func tokenRangesUseUTF16Offsets() {
        let prefix = "// 🧪\n"
        let result = PL0Lexer().tokenize(SourceSnapshot(version: 1,
                                                        text: prefix + "var x;."))
        let variable = result.tokens.first { $0.kind == .varKeyword }

        #expect(variable?.range.location == (prefix as NSString).length)
        #expect(variable?.location.line == 2)
        #expect(variable?.location.column == 1)
    }

    @Test func unterminatedCommentProducesBoundedDiagnostic() {
        let result = PL0Frontend().parse(SourceSnapshot(
            version: 5, text: "var x; /* unfinished"))

        #expect(result.diagnostics.contains { $0.message == "Unterminated block comment" })
        #expect(result.root.kind == "Program")
    }
}
