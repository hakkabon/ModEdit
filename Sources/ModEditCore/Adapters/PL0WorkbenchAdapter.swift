import Foundation
import PL0Language

/// Presentation-sized recognition evidence. ModEdit does not own parser
/// configurations or execute parser algorithms; it only renders this summary.
struct PL0RecognitionSummary: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let accepted: Bool
    let detail: String
}

struct PL0WorkbenchAnalysis: Sendable {
    let parse: ParseResult
    let semantics: PL0SemanticModel
    let recognizers: [PL0RecognitionSummary]
}

struct PL0WorkbenchExecution: Sendable {
    let program: PL0Program
    let result: PL0ExecutionResult
}

/// The sole language-service boundary used by ModEdit's PL/0 workbench.
///
/// All lexing, parsing, recovery, semantic analysis, formatting, compilation,
/// execution and ecosystem comparison remain owned by PL0-LanguageKit and its
/// engine dependencies. ModEdit supplies snapshots and renders returned data.
actor PL0WorkbenchAdapter {
    private let session: PL0LanguageSession

    init(engine: ParserEngine = .referenceLL) {
        session = PL0LanguageSession(engine: engine)
    }

    func analyze(_ snapshot: SourceSnapshot) async -> PL0WorkbenchAnalysis {
        let analysis = await session.analyze(snapshot)
        let parse = analysis.parse
        let input = ParserInput(tokens: parse.tokens, lexicalDiagnostics: [])
        let lr = LRPL0Parser().recognize(input)
        let earley = EarleyPL0Parser().recognize(input)
        return PL0WorkbenchAnalysis(
            parse: parse,
            semantics: analysis.semantics,
            recognizers: [
                .init(id: "reference-ll", name: "Reference LL",
                      accepted: parse.diagnostics.isEmpty,
                      detail: "normalized CST and recovery oracle"),
                .init(id: "generated-slr", name: "Generated SLR(1)",
                      accepted: lr.accepted,
                      detail: "\(lr.configurationCount) actions · stack \(lr.maximumFrontierSize) · consumed \(lr.consumedTokenCount)"),
                .init(id: "earley-chart", name: "Earley Chart",
                      accepted: earley.accepted,
                      detail: "\(earley.configurationCount) items · chart max \(earley.maximumFrontierSize) · consumed \(earley.consumedTokenCount)"),
            ]
        )
    }

    func compare(_ snapshot: SourceSnapshot) async throws -> EcosystemParserComparison {
        try await session.compare(snapshot)
    }

    func format(_ snapshot: SourceSnapshot) async throws -> String {
        try await session.format(snapshot)
    }

    func compileAndRun(_ snapshot: SourceSnapshot) async throws -> PL0WorkbenchExecution {
        let program = try await session.compile(snapshot)
        let result = try PL0VirtualMachine().run(program)
        return .init(program: program, result: result)
    }
}
