import Testing
@testable import PL0Language

@Suite("PL/0 LR and Earley parsers")
struct GrammarParserTests {
    private let corpus = [
        ".",
        "const a = 1, b = 2; .",
        "var x, y; x := -1 + 2 * (3 + y).",
        "procedure p; call p; call p.",
        "begin call p; if odd x then x := x + 1; while x # 0 do x := x - 1 end.",
        "begin if x <= 10 then x := 1; if x >= 2 then x := 0 end.",
    ]

    @Test func descriptorsPublishDifferentAlgorithms() {
        #expect(LRPL0Parser().descriptor.id == "slr-1")
        #expect(EarleyPL0Parser().descriptor.id == "earley")
        #expect(EarleyPL0Parser().descriptor.capabilities.contains(.ambiguity))
        #expect(!LRPL0Parser().descriptor.capabilities.contains(.ambiguity))
    }

    @Test func bothRecognizersAcceptControlledCorpus() {
        for source in corpus {
            let snapshot = SourceSnapshot(version: 1, text: source)
            let lexed = PL0Lexer().tokenize(snapshot)
            let input = ParserInput(tokens: lexed.tokens,
                                    lexicalDiagnostics: lexed.diagnostics)
            #expect(LRPL0Parser().recognize(input).accepted, "LR rejected: \(source)")
            #expect(EarleyPL0Parser().recognize(input).accepted, "Earley rejected: \(source)")
        }
    }

    @Test func bothRecognizersRejectMalformedPrograms() {
        for source in ["var ; .", "begin x := end.", "if odd then .", "const x = ; ."] {
            let lexed = PL0Lexer().tokenize(SourceSnapshot(version: 1, text: source))
            let input = ParserInput(tokens: lexed.tokens,
                                    lexicalDiagnostics: lexed.diagnostics)
            #expect(!LRPL0Parser().recognize(input).accepted, "LR accepted: \(source)")
            #expect(!EarleyPL0Parser().recognize(input).accepted, "Earley accepted: \(source)")
        }
    }

    @Test func frontendSelectsEveryEngineAndNormalizesTheSameCST() {
        let snapshot = SourceSnapshot(version: 7,
                                      text: "var x; begin x := 1; x := x + 1 end.")
        let results = ParserEngine.allCases.map { PL0Frontend(engine: $0).parse(snapshot) }
        #expect(results.map(\.parser.id) == ["reference-ll", "slr-1", "earley"])
        #expect(results.allSatisfy { $0.diagnostics.isEmpty })
        #expect(results.dropFirst().allSatisfy { $0.syntaxTree == results[0].syntaxTree })
    }

    @Test func malformedInputRetainsCommonRecoveryContract() {
        let snapshot = SourceSnapshot(version: 2, text: "var x; if x < 10 x := 1.")
        let results = ParserEngine.allCases.map { PL0Frontend(engine: $0).parse(snapshot) }
        #expect(results.allSatisfy { $0.diagnostics.contains { $0.expected.contains(.then) } })
        #expect(results.dropFirst().allSatisfy { $0.recovery == results[0].recovery })
    }

    @Test func recognitionMetricsExposeAlgorithmShape() {
        let lexed = PL0Lexer().tokenize(SourceSnapshot(
            version: 1, text: "var x; begin x := 1; while x < 4 do x := x + 1 end."))
        let input = ParserInput(tokens: lexed.tokens, lexicalDiagnostics: [])
        let lr = LRPL0Parser().recognize(input)
        let earley = EarleyPL0Parser().recognize(input)
        #expect(lr.configurationCount > lr.consumedTokenCount)
        #expect(earley.configurationCount > earley.consumedTokenCount)
        #expect(lr.maximumFrontierSize > 0)
        #expect(earley.maximumFrontierSize > 0)
    }
}
