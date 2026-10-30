import Foundation
import Testing
@testable import PL0Language

/// Opt-in parser benchmark. Run through scripts/benchmark-pl0.sh so optimized
/// timings, corpus sizes and the enabling environment variable stay stable.
@Suite("PL/0 parser benchmark", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MODEDIT_PL0_BENCHMARK"] == "1"))
struct PL0ParserBenchmarkTests {
    // Earley's packed forest exposes the controlled grammar's statement-list
    // ambiguity and grows quadratically; 500 statements keeps this diagnostic
    // benchmark repeatable without hiding that growth or exhausting CI hosts.
    @Test(arguments: [100, 250, 500])
    func benchmark(statementCount: Int) async {
        let source = makeProgram(statementCount: statementCount)
        let snapshot = SourceSnapshot(version: 1, text: source)

        var lexed: LexResult!
        let lexTime = measure { lexed = PL0Lexer().tokenize(snapshot) }
        report(statements: statementCount, tokens: lexed.tokens.count,
               operation: "full lexer", seconds: lexTime)

        for engine in ParserEngine.allCases {
            var result: ParseResult!
            let duration = measure {
                result = PL0Frontend(engine: engine).parse(snapshot)
            }
            #expect(result.diagnostics.isEmpty)
            report(statements: statementCount, tokens: result.metrics.tokenCount,
                   operation: "full \(engine.rawValue)", seconds: duration)
        }

        let input = ParserInput(tokens: lexed.tokens,
                                lexicalDiagnostics: lexed.diagnostics)
        var lrArtifact: LRParseArtifact!
        let lrTime = measure { lrArtifact = LRPL0Parser().parseDetailed(input) }
        report(statements: statementCount, tokens: lexed.tokens.count,
               operation: "LR tree+trace", seconds: lrTime,
               detail: "\(lrArtifact.trace.count) events")

        var earleyArtifact: EarleyParseArtifact!
        let earleyTime = measure {
            earleyArtifact = EarleyPL0Parser().parseDetailed(input)
        }
        report(statements: statementCount, tokens: lexed.tokens.count,
               operation: "Earley forest+trace", seconds: earleyTime,
               detail: "\(earleyArtifact.forest?.nodes.count ?? 0) nodes / \(earleyArtifact.trace.count) events")

        for engine in ParserEngine.allCases {
            let session = PL0LanguageSession(engine: engine)
            _ = await session.parse(snapshot)
            let oldDigit = String((statementCount - 1) % 10)
            let range = (source as NSString).range(
                of: "x := x + \(oldDigit)", options: .backwards)
            let digit = range.location + range.length - 1
            let newDigit = oldDigit == "9" ? "8" : "9"
            let changed = (source as NSString).replacingCharacters(
                in: NSRange(location: digit, length: 1), with: newDigit)
            var incremental: ParseResult!
            let duration = await measureAsync {
                incremental = await session.parse(SourceSnapshot(
                    version: 2, text: changed,
                    edit: SourceEdit(baseVersion: 1,
                                     replacedRange: SourceRange(location: digit, length: 1),
                                     replacementLength: 1)))
            }
            let reuse: String = switch incremental.algorithmArtifact {
            case let .lr(artifact): "reused \(artifact.reusedTokenCount) tokens"
            case let .earley(artifact): "reused \(artifact.reusedChartColumnCount) columns"
            case nil: "reused \(incremental.metrics.incrementalParsing.reusedTokenCount) tokens"
            }
            report(statements: statementCount,
                   tokens: incremental.metrics.tokenCount,
                   operation: "incremental \(engine.rawValue)",
                   seconds: duration, detail: reuse)
        }
    }

    private func makeProgram(statementCount: Int) -> String {
        let statements = (0..<statementCount).map { index in
            index == 0 ? "x := 0" : "x := x + \(index % 10)"
        }.joined(separator: "; ")
        return "var x; begin \(statements) end."
    }

    private func measure(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        return seconds(start.duration(to: .now))
    }

    private func measureAsync(_ body: () async -> Void) async -> Double {
        let start = ContinuousClock.now
        await body()
        return seconds(start.duration(to: .now))
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func report(statements: Int, tokens: Int, operation: String,
                        seconds: Double, detail: String = "") {
        let milliseconds = seconds * 1_000
        let nanosecondsPerToken = seconds * 1e9 / Double(max(1, tokens))
        print(String(format: "PL0BENCH %5d stmts %7d tokens  %-30@ %10.3f ms %10.1f ns/token  %@",
                     statements, tokens, operation as NSString, milliseconds,
                     nanosecondsPerToken, detail as NSString))
    }
}
