import Foundation
import Testing
@testable import PL0Language

@Suite("PL/0 mutation campaigns", .serialized)
struct PL0MutationSuiteTests {
    private let seeds = [
        ".",
        "const n = 3; var x; begin x := n end.",
        "var x; begin x := 0; while x < 4 do x := x + 1 end.",
        "var x; procedure p; begin x := x + 1 end; begin x := 0; call p end.",
        "var x; begin if odd x then x := (x + 1) * 2 end.",
    ]

    @Test func everySingleTokenDeletionTerminatesAndEnginesAgree() {
        for seed in seeds {
            let tokens = PL0Lexer().tokenize(SourceSnapshot(version: 1, text: seed))
                .tokens.filter { $0.kind != .endOfFile }
            for token in tokens {
                let mutated = (seed as NSString).replacingCharacters(
                    in: NSRange(location: token.range.location,
                                length: token.range.length), with: "")
                checkMutation(mutated, context: "delete \(token.lexeme) from \(seed)")
            }
        }
    }

    @Test func representativeTokenInsertionsTerminateAndEnginesAgree() {
        let insertions = [";", "begin ", " end", ":=", "(", ")", "if ", " 123 ", "@"]
        for seed in seeds {
            let lexed = PL0Lexer().tokenize(SourceSnapshot(version: 1, text: seed))
            let boundaries = [0] + lexed.tokens
                .filter { $0.kind != .endOfFile }
                .map(\.range.end)
            for (index, boundary) in boundaries.enumerated() {
                let insertion = insertions[index % insertions.count]
                let mutated = (seed as NSString).replacingCharacters(
                    in: NSRange(location: boundary, length: 0), with: insertion)
                checkMutation(mutated, context: "insert \(insertion) into \(seed)")
            }
        }
    }

    @Test func seededRandomMutationsStayBoundedAndIncrementalMatchesFull() async {
        var random = MutationRNG(state: 0xC0FFEE_5EED)
        var text = seeds[2]
        var version: UInt64 = 1
        let sessions = Dictionary(uniqueKeysWithValues: ParserEngine.allCases.map {
            ($0, PL0LanguageSession(engine: $0))
        })
        for session in sessions.values {
            _ = await session.parse(SourceSnapshot(version: version, text: text))
        }
        let fragments = ["", "x", "0", "12", " ", "\n", ";", ":=", "+", "#",
                         "begin", "end", "while", "/*", "*/", "// mutation\n", "@"]
        var observedReuse: [ParserEngine: Bool] = [:]

        for _ in 0..<200 {
            let length = (text as NSString).length
            let location = random.next(upperBound: length + 1)
            let deletion = random.next(upperBound: min(4, length - location) + 1)
            let replacement = fragments[random.next(upperBound: fragments.count)]
            let range = NSRange(location: location, length: deletion)
            var next = (text as NSString).replacingCharacters(in: range,
                                                               with: replacement)
            let reset = (next as NSString).length > 2_000
            if reset { next = seeds[2] }
            let effectiveRange = reset
                ? NSRange(location: 0, length: length) : range
            let effectiveReplacement = reset ? seeds[2] : replacement
            let oldVersion = version
            version += 1
            let edit = SourceEdit(
                baseVersion: oldVersion,
                replacedRange: SourceRange(location: effectiveRange.location,
                                           length: effectiveRange.length),
                replacementLength: (effectiveReplacement as NSString).length)

            for engine in ParserEngine.allCases {
                let incremental = await sessions[engine]!.parse(SourceSnapshot(
                    version: version, text: next, edit: edit))
                let full = PL0Frontend(engine: engine).parse(
                    SourceSnapshot(version: version, text: next))
                expectEquivalent(incremental, full,
                                 context: "\(engine.rawValue) mutation \(version)")
                #expect(incremental.recoveryActions.count
                        <= incremental.tokens.count * 4 + 4)
                switch incremental.algorithmArtifact {
                case let .lr(artifact):
                    observedReuse[engine] = observedReuse[engine] == true
                        || artifact.reusedTokenCount > 0
                case let .earley(artifact):
                    observedReuse[engine] = observedReuse[engine] == true
                        || artifact.reusedChartColumnCount > 0
                case nil:
                    observedReuse[engine] = observedReuse[engine] == true
                        || incremental.metrics.incrementalParsing.reusedTokenCount > 0
                }
            }
            checkRecognizerAgreement(next, context: "random mutation \(version)")
            text = next
        }

        #expect(observedReuse[.referenceLL] == true)
        #expect(observedReuse[.generatedLR] == true)
        #expect(observedReuse[.earley] == true)
    }

    @Test func mutationCampaignIsReproducibleForThePublishedSeed() {
        var first = MutationRNG(state: 0xC0FFEE_5EED)
        var second = MutationRNG(state: 0xC0FFEE_5EED)
        #expect((0..<100).map { _ in first.next(upperBound: 10_000) }
                == (0..<100).map { _ in second.next(upperBound: 10_000) })
    }

    private func checkMutation(_ source: String, context: String) {
        for engine in ParserEngine.allCases {
            let result = PL0Frontend(engine: engine).parse(
                SourceSnapshot(version: 1, text: source))
            #expect(result.root.kind == "Program", "\(context): \(engine.rawValue)")
            #expect(result.recoveryActions.count <= result.tokens.count * 4 + 4,
                    "\(context): unbounded recovery")
        }
        checkRecognizerAgreement(source, context: context)
    }

    private func checkRecognizerAgreement(_ source: String, context: String) {
        let lexed = PL0Lexer().tokenize(SourceSnapshot(version: 1, text: source))
        let input = ParserInput(tokens: lexed.tokens,
                                lexicalDiagnostics: lexed.diagnostics)
        let lr = LRPL0Parser().recognize(input)
        let earley = EarleyPL0Parser().recognize(input)
        #expect(lr.accepted == earley.accepted,
                "\(context): LR=\(lr.accepted), Earley=\(earley.accepted)")
        #expect(lr.configurationCount <= max(1_000, lexed.tokens.count * 20))
        #expect(earley.configurationCount < 1_000_000,
                "\(context): Earley item growth exceeded campaign bound")
    }

    private func expectEquivalent(_ incremental: ParseResult, _ full: ParseResult,
                                  context: String) {
        #expect(incremental.syntaxTree == full.syntaxTree, "\(context): CST differs")
        #expect(incremental.diagnostics == full.diagnostics,
                "\(context): diagnostics differ")
        #expect(incremental.recovery.events.map(RecoveryView.init)
                == full.recovery.events.map(RecoveryView.init),
                "\(context): recovery decisions differ")
        #expect(incremental.expectations == full.expectations,
                "\(context): expectations differ")
    }

    private struct RecoveryView: Equatable {
        let sequence: Int
        let summary: String
        let range: SourceRange
        let expected: [PL0TokenKind]
        let diagnosticIDs: [String]
        let cost: Int

        init(_ event: RecoveryEvent) {
            sequence = event.sequence
            summary = event.action.summary
            range = event.action.range
            expected = event.expected
            diagnosticIDs = event.diagnosticIDs
            cost = event.cost
        }
    }
}

private struct MutationRNG {
    var state: UInt64

    mutating func next(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
        return Int(state % UInt64(upperBound))
    }
}
