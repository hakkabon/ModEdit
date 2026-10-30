import Foundation
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

    @Test func frontendSelectsEveryEngineAndRetainsTheSameConcreteTokens() {
        let snapshot = SourceSnapshot(version: 7,
                                      text: "var x; begin x := 1; x := x + 1 end.")
        let results = ParserEngine.allCases.map { PL0Frontend(engine: $0).parse(snapshot) }
        #expect(results.map(\.parser.id) == ["reference-ll", "slr-1", "earley"])
        #expect(results.allSatisfy { $0.diagnostics.isEmpty })
        #expect(results.map(\.root.kind) == ["Program", "Program", "Program"])
        #expect(results.dropFirst().allSatisfy {
            $0.syntaxTree.terminals == results[0].syntaxTree.terminals
        })
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

    @Test func lrBuildsNativeReductionTreeAndDetailedTrace() {
        let input = parserInput("var x; begin x := 1; x := x + 1 end.")
        let artifact = LRPL0Parser().parseDetailed(input)
        #expect(artifact.recognition.accepted)
        #expect(artifact.root?.kind == "Program")
        #expect(artifact.root?.outline().contains("Expression") == true)
        #expect(artifact.trace.contains { $0.action == .shift })
        #expect(artifact.trace.contains { $0.action == .reduce && $0.detail.contains("Expression") })
        #expect(artifact.trace.last?.action == .accept)
    }

    @Test func earleyBuildsPackedForestAndDetailedTrace() {
        let artifact = EarleyPL0Parser().parseDetailed(
            parserInput("var x; begin x := 1 end."))
        #expect(artifact.recognition.accepted)
        #expect(artifact.forest?.root?.symbol == "Program")
        #expect((artifact.forest?.nodes.count ?? 0) > 10)
        #expect((artifact.forest?.packedAlternativeCount ?? 0) > 5)
        #expect(artifact.trace.contains { $0.action == .predict })
        #expect(artifact.trace.contains { $0.action == .scan })
        #expect(artifact.trace.contains { $0.action == .complete })
        #expect(artifact.trace.last?.action == .accept)
    }

    @Test func incrementalLRResumesAtStableTokenCheckpoint() {
        let old = "var x; begin x := 1; x := x + 1 end."
        let new = "var x; begin x := 2; x := x + 1 end."
        let (first, second) = incrementallyTokenized(old: old, new: new,
                                                     replacing: "1", with: "2")
        var parser = IncrementalLRPL0Parser()
        let initial = parser.parse(ParserInput(tokens: first.tokens,
                                               lexicalDiagnostics: first.diagnostics))
        let changed = parser.parse(ParserInput(tokens: second.tokens,
                                               lexicalDiagnostics: second.diagnostics))
        let full = LRPL0Parser().parseDetailed(ParserInput(tokens: second.tokens,
                                                           lexicalDiagnostics: []))
        #expect(initial.recognition.accepted)
        #expect(changed.recognition.accepted)
        #expect(changed.reusedTokenCount > 0)
        #expect(changed.trace.first?.action == .reuse)
        #expect(changed.root == full.root)
    }

    @Test func incrementalEarleyReusesClosedChartColumns() {
        let old = "var x; begin x := 1; x := x + 1 end."
        let new = "var x; begin x := 2; x := x + 1 end."
        let (first, second) = incrementallyTokenized(old: old, new: new,
                                                     replacing: "1", with: "2")
        var parser = IncrementalEarleyPL0Parser()
        _ = parser.parse(ParserInput(tokens: first.tokens,
                                     lexicalDiagnostics: first.diagnostics))
        let changed = parser.parse(ParserInput(tokens: second.tokens,
                                               lexicalDiagnostics: second.diagnostics))
        let full = EarleyPL0Parser().parseDetailed(ParserInput(tokens: second.tokens,
                                                               lexicalDiagnostics: []))
        #expect(changed.recognition.accepted)
        #expect(changed.reusedChartColumnCount > 0)
        #expect(changed.trace.first?.action == .reuse)
        #expect(changed.forest == full.forest)
    }

    @Test func languageSessionPublishesIncrementalLRArtifact() async {
        let old = "var x; begin x := 1; x := x + 1 end."
        let new = "var x; begin x := 2; x := x + 1 end."
        let location = (old as NSString).range(of: "1").location
        let session = PL0LanguageSession(engine: .generatedLR)
        let first = await session.parse(SourceSnapshot(version: 1, text: old))
        let second = await session.parse(SourceSnapshot(
            version: 2, text: new,
            edit: SourceEdit(baseVersion: 1,
                             replacedRange: SourceRange(location: location, length: 1),
                             replacementLength: 1)))
        guard case let .lr(firstArtifact) = first.algorithmArtifact,
              case let .lr(secondArtifact) = second.algorithmArtifact else {
            Issue.record("Expected LR artifacts")
            return
        }
        #expect(firstArtifact.reusedTokenCount == 0)
        #expect(secondArtifact.reusedTokenCount > 0)
        #expect(second.root.kind == "Program")
    }

    @Test func languageSessionPublishesIncrementalEarleyForest() async {
        let old = "var x; begin x := 1; x := x + 1 end."
        let new = "var x; begin x := 2; x := x + 1 end."
        let location = (old as NSString).range(of: "1").location
        let session = PL0LanguageSession(engine: .earley)
        _ = await session.parse(SourceSnapshot(version: 1, text: old))
        let second = await session.parse(SourceSnapshot(
            version: 2, text: new,
            edit: SourceEdit(baseVersion: 1,
                             replacedRange: SourceRange(location: location, length: 1),
                             replacementLength: 1)))
        guard case let .earley(artifact) = second.algorithmArtifact else {
            Issue.record("Expected Earley artifact")
            return
        }
        #expect(artifact.reusedChartColumnCount > 0)
        #expect(artifact.forest?.root?.symbol == "Program")
        #expect(second.root.kind == "Program")
    }

    @Test func repeatedIncrementalRunsMatchFreshLRTreeAndEarleyForest() {
        var text = "var x; begin x := 1; while x < 5 do x := x + 1 end."
        var version: UInt64 = 1
        var tokenizer = PL0IncrementalTokenizer()
        var lr = IncrementalLRPL0Parser()
        var earley = IncrementalEarleyPL0Parser()
        var lexed = tokenizer.tokenize(SourceSnapshot(version: version, text: text)).lexed
        _ = lr.parse(ParserInput(tokens: lexed.tokens, lexicalDiagnostics: lexed.diagnostics))
        _ = earley.parse(ParserInput(tokens: lexed.tokens, lexicalDiagnostics: lexed.diagnostics))

        for replacement in ["2", "3", "4"] {
            let range = (text as NSString).range(of: "x := \(Int(replacement)! - 1)")
            let digit = range.location + range.length - 1
            let next = (text as NSString).replacingCharacters(
                in: NSRange(location: digit, length: 1), with: replacement)
            let edit = SourceEdit(baseVersion: version,
                                  replacedRange: SourceRange(location: digit, length: 1),
                                  replacementLength: 1)
            version += 1
            text = next
            lexed = tokenizer.tokenize(SourceSnapshot(version: version, text: text,
                                                       edit: edit)).lexed
            let input = ParserInput(tokens: lexed.tokens,
                                    lexicalDiagnostics: lexed.diagnostics)
            let incrementalLR = lr.parse(input)
            let incrementalEarley = earley.parse(input)
            #expect(incrementalLR.root == LRPL0Parser().parseDetailed(input).root)
            #expect(incrementalEarley.forest == EarleyPL0Parser().parseDetailed(input).forest)
            #expect(incrementalLR.reusedTokenCount > 0)
            #expect(incrementalEarley.reusedChartColumnCount > 0)
        }
    }

    private func parserInput(_ source: String) -> ParserInput {
        let lexed = PL0Lexer().tokenize(SourceSnapshot(version: 1, text: source))
        return ParserInput(tokens: lexed.tokens, lexicalDiagnostics: lexed.diagnostics)
    }

    private func incrementallyTokenized(old: String, new: String,
                                        replacing needle: String,
                                        with replacement: String) -> (LexResult, LexResult) {
        var tokenizer = PL0IncrementalTokenizer()
        let first = tokenizer.tokenize(SourceSnapshot(version: 1, text: old)).lexed
        let range = (old as NSString).range(of: needle)
        let edit = SourceEdit(baseVersion: 1,
                              replacedRange: SourceRange(location: range.location,
                                                         length: range.length),
                              replacementLength: (replacement as NSString).length)
        let second = tokenizer.tokenize(SourceSnapshot(version: 2, text: new,
                                                        edit: edit)).lexed
        return (first, second)
    }
}
