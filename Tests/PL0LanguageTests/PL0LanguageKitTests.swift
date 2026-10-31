import Foundation
import Testing
@testable import PL0Language

@Suite("PL/0 single-source language kit")
struct PL0LanguageKitTests {
    @Test func bundledGrammarCompilesToTypedArtifact() {
        let artifact = PL0LanguageKit.bundled.artifact

        #expect(artifact.startSymbol == "Program")
        #expect(artifact.tokenDefinitions.count == 29)
        #expect(artifact.productions.count == 43)
        #expect(Set(artifact.productions.map(\.lhs)).count == PL0Nonterminal.allCases.count)
        #expect(artifact.fingerprint == artifact.grammarIdentity.fingerprint)
        #expect(artifact.skipPatterns.count == 3)
    }

    @Test func lexicalClassificationComesFromGrammarArtifact() throws {
        let source = PL0LanguageKit.bundled.artifact.source
            .replacingOccurrences(of: "%token CALL /call\\b/",
                                  with: "%token CALL /invoke\\b/")
        let kit = try PL0LanguageKit.compile(source: source, revision: 2)
        let lexed = PL0Lexer(languageKit: kit).tokenize(
            SourceSnapshot(version: 1, text: "invoke p."))

        #expect(lexed.tokens.map(\.kind).prefix(2) == [.call, .identifier])
        #expect(lexed.tokens.first?.lexeme == "invoke")
        #expect(kit.artifact.fingerprint != PL0LanguageKit.bundled.artifact.fingerprint)
    }

    @Test func generatedParsersConsumeCompiledProductions() throws {
        let source = PL0LanguageKit.bundled.artifact.source
            .replacingOccurrences(of: "          | CALL IDENTIFIER\n", with: "")
        let kit = try PL0LanguageKit.compile(source: source, revision: 2)
        let lexed = PL0Lexer(languageKit: kit).tokenize(
            SourceSnapshot(version: 1, text: "call p."))
        let input = ParserInput(tokens: lexed.tokens,
                                lexicalDiagnostics: lexed.diagnostics)

        #expect(!LRPL0Parser(languageKit: kit).recognize(input).accepted)
        #expect(!EarleyPL0Parser(languageKit: kit).recognize(input).accepted)
        #expect(LRPL0Parser().recognize(input).accepted)
    }

    @Test func losslessStreamReconstructsSourceAndClassifiesTrivia() {
        let source = "var  x; // note\r\n/* block */ begin x := 1 end."
        let lexed = PL0Lexer().tokenize(SourceSnapshot(version: 1, text: source))

        #expect(lexed.losslessTokens.map(\.lexeme).joined() == source)
        #expect(lexed.losslessTokens.contains { $0.kind == .trivia(.whitespace) })
        #expect(lexed.losslessTokens.contains { $0.kind == .trivia(.lineComment) })
        #expect(lexed.losslessTokens.contains { $0.kind == .trivia(.blockComment) })
    }

    @Test func nonBMPInvalidInputRemainsOneLosslessLexeme() {
        let source = "😀."
        let lexed = PL0Lexer().tokenize(SourceSnapshot(version: 1, text: source))

        #expect(lexed.tokens.first?.kind == .invalid)
        #expect(lexed.tokens.first?.range.length == 2)
        #expect(lexed.losslessTokens.map(\.lexeme).joined() == source)
    }

    @Test func compilerRejectsUnknownAndMissingTypedSymbols() {
        let source = PL0LanguageKit.bundled.artifact.source
            .replacingOccurrences(of: "%token CALL /call\\b/\n", with: "")

        #expect(throws: PL0LanguageKitError.self) {
            try PL0LanguageKit.compile(source: source)
        }
    }
}
