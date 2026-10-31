import CYK_Parser
import Earley_Parser
import Earley_TableParser
import Foundation
import Grammar
import LanguageExperimentProtocol
import LL_Parsing
import LR_Parsing
import Parser
import RNGLR_Parser

public enum EcosystemParserEngine: String, CaseIterable, Codable, Sendable, Hashable {
    case earley
    case earleySL = "earley-sl"
    case earleyEL = "earley-el"
    case cyk
    case rnglr
    case ll1
    case lr0
    case slr
    case lalr
    case lr1

    public var displayName: String {
        switch self {
        case .earley: "Earley"
        case .earleySL: "Earley Table SL"
        case .earleyEL: "Earley Table EL"
        case .cyk: "CYK"
        case .rnglr: "RNGLR"
        case .ll1: "LL(1)"
        case .lr0: "LR(0)"
        case .slr: "SLR(1)"
        case .lalr: "LALR(1)"
        case .lr1: "Canonical LR(1)"
        }
    }
}

public struct EcosystemParserObservation: Codable, Sendable, Equatable, Identifiable {
    public let parser: EcosystemParserEngine
    public let status: String
    public let derivations: Int
    public let forestNodes: Int?
    public let ambiguous: Bool?
    public let productionIdentified: Bool
    public let replayEvents: [String]
    public let supported: Bool
    public let unsupportedReason: String?
    public var id: EcosystemParserEngine { parser }
    public var accepted: Bool { status == "accepted" || status == "acceptedWithRecovery" }
}

public enum EcosystemParserAgreement: String, Codable, Sendable, Equatable {
    case complete, divergent, inconclusive
}

public struct EcosystemParserComparison: Codable, Sendable, Equatable {
    public let revision: UInt64
    public let grammarFingerprint: String
    public let sourceFingerprint: String
    public let engines: [EcosystemParserObservation]
    public let agreement: EcosystemParserAgreement

    public init(revision: UInt64, grammarFingerprint: String,
                sourceFingerprint: String, engines: [EcosystemParserObservation]) {
        self.revision = revision
        self.grammarFingerprint = grammarFingerprint
        self.sourceFingerprint = sourceFingerprint
        self.engines = engines
        let supported = engines.filter(\.supported)
        agreement = supported.count < 2 ? .inconclusive
            : Set(supported.map(\.accepted)).count == 1 ? .complete : .divergent
    }
}

/// Runs the linked Grammar/Parser ecosystem packages directly. The comparison
/// has no duplicated engine implementation and no Grammar-REPL subprocess.
public actor PL0EcosystemParserSession {
    private let languageKit: PL0LanguageKit

    public init(languageKit: PL0LanguageKit = .bundled) {
        self.languageKit = languageKit
    }

    public func compare(_ snapshot: SourceSnapshot) throws -> EcosystemParserComparison {
        let lexed = PL0Lexer(languageKit: languageKit).tokenize(snapshot)
        let input = ParserInput(tokens: lexed.tokens,
                                lexicalDiagnostics: lexed.diagnostics,
                                source: snapshot.text)
        let stream = try PL0EcosystemTokenStream(input)
        let grammar = ecosystemGrammar(languageKit.artifact)
        let engines = EcosystemParserEngine.allCases.map {
            run($0, grammar: grammar, stream: stream)
        }
        return EcosystemParserComparison(
            revision: snapshot.version,
            grammarFingerprint: languageKit.artifact.fingerprint,
            sourceFingerprint: StableFingerprint.fnv1a64(snapshot.text),
            engines: engines)
    }

    private func run(_ engine: EcosystemParserEngine, grammar: Grammar,
                     stream: PL0EcosystemTokenStream) -> EcosystemParserObservation {
        do {
            switch engine {
            case .earley:
                return try generalized(engine,
                    Earley_Parser.EarleyParser(grammar: grammar).parse(stream: stream))
            case .earleySL, .earleyEL:
                return try generalized(engine, Earley_TableParser.EarleyTableParser(
                    grammar: grammar, useExtendedLookahead: engine == .earleyEL)
                    .parse(stream: stream))
            case .cyk:
                return try generalized(engine,
                    CYK_Parser.CYKParser(grammar: grammar).parse(stream: stream))
            case .rnglr:
                // RNGLR 0.2.x predates TokenStream conformance. Feed it the
                // same normalized terminal names, not the PL/0 lexemes.
                let normalized = stream.tokens.map { $0.kind.grammarName }
                    .joined(separator: " ")
                return try generalized(engine,
                    RNGLR_Parser.RNGLRParser(grammar: grammar).parse(normalized))
            case .ll1:
                let result = LL_Parsing.LLParser(grammar: grammar)
                    .parseWithRecovery(stream: stream)
                return deterministic(engine, status: result.status,
                    replay: ["start"] + stream.tokens.indices.map { _ in "consume" }
                        + [result.status == .rejected ? "reject" : "accept"])
            case .lr0, .slr, .lalr, .lr1:
                let algorithm: LR_Parsing.LRParser.Algorithm = switch engine {
                case .lr0: .lr0
                case .slr: .slr
                case .lalr: .lalr
                case .lr1: .lr1
                default: preconditionFailure("not an LR engine")
                }
                let result = try LR_Parsing.LRParser(
                    grammar: grammar, algorithm: algorithm).parseOutcome(
                        stream: stream, recovery: LR_Parsing.RecoveryPolicy.none,
                        tracing: true)
                let events = result.trace.map {
                    $0.parseContractEvent.kind.rawValue
                }
                return deterministic(engine, status: result.status,
                    replay: events.isEmpty
                        ? ["start", result.status == .rejected ? "reject" : "accept"]
                        : events)
            }
        } catch {
            return EcosystemParserObservation(
                parser: engine, status: "rejected", derivations: 0,
                forestNodes: nil, ambiguous: nil,
                productionIdentified: false,
                replayEvents: ["start", "reject"], supported: true,
                unsupportedReason: String(describing: error))
        }
    }
}

private func generalized<Label>(
    _ engine: EcosystemParserEngine, _ result: Parser.ParseResult<Label>
) throws -> EcosystemParserObservation
where Label: ProductionIdentifiedSPPFLabel & Codable {
    let forest = try result.sppfGraph?.portableSnapshot()
    let identified = forest?.nodes.filter {
        $0.kind == .intermediate || $0.kind == .packed
    }.allSatisfy { $0.productionID != nil } ?? false
    let accepted = result.isSuccessful
    var replay = ["start"]
    replay += forest?.nodes.map { node in
        switch node.kind {
        case .token: "consume"
        case .symbol: "inspect"
        case .intermediate, .packed: "applyProduction"
        }
    } ?? []
    replay.append(accepted ? "accept" : "reject")
    return EcosystemParserObservation(
        parser: engine, status: accepted ? "accepted" : "rejected",
        derivations: accepted ? 1 : 0,
        forestNodes: forest?.nodes.count,
        ambiguous: forest.map { !$0.ambiguityNodes.isEmpty },
        productionIdentified: identified, replayEvents: replay,
        supported: true, unsupportedReason: nil)
}

private func deterministic(_ engine: EcosystemParserEngine,
                           status: Parser.ParseStatus,
                           replay: [String]) -> EcosystemParserObservation {
    let statusName: String = switch status {
    case .accepted: "accepted"
    case .recovered: "acceptedWithRecovery"
    case .rejected: "rejected"
    }
    return EcosystemParserObservation(
        parser: engine,
        status: statusName,
        derivations: status == .rejected ? 0 : 1,
        forestNodes: nil, ambiguous: nil, productionIdentified: false,
        replayEvents: replay, supported: true, unsupportedReason: nil)
}
