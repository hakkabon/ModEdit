import Foundation
import LanguageExperimentProtocol

public protocol EcosystemParserTransport: Sendable {
    func evaluate(_ corpus: Data) async throws -> Data
}

public enum EcosystemParserBridgeError: Error, Sendable, Equatable, CustomStringConvertible {
    case launch(String)
    case processFailed(status: Int32, message: String)
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .launch(let message): "Could not launch Grammar-REPL conformance adapter: \(message)"
        case let .processFailed(status, message):
            "Grammar-REPL conformance adapter exited with status \(status): \(message)"
        case .invalidResponse(let message): "Invalid Grammar-REPL engine response: \(message)"
        }
    }
}

/// Executes Grammar-REPL's non-interactive corpus adapter. That executable owns
/// the actual Grammar, Parser, LL, LR, Earley, Earley Table, CYK, and RNGLR
/// dependencies, avoiding duplicate Swift modules inside the editor process.
public actor GrammarREPLConformanceProcessTransport: EcosystemParserTransport {
    private let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public func evaluate(_ corpus: Data) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("modedit-grammar-repl-\(UUID().uuidString)",
                                    isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory,
                                                      withIntermediateDirectories: true) }
        catch { throw EcosystemParserBridgeError.launch(error.localizedDescription) }
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("corpus.json")
        let output = directory.appendingPathComponent("observations.json")
        do { try corpus.write(to: input, options: .atomic) }
        catch { throw EcosystemParserBridgeError.launch(error.localizedDescription) }

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = [input.path, output.path]
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        do { try process.run() }
        catch { throw EcosystemParserBridgeError.launch(error.localizedDescription) }
        process.waitUntilExit()
        let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw EcosystemParserBridgeError.processFailed(
                status: process.terminationStatus,
                message: errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do { return try Data(contentsOf: output) }
        catch { throw EcosystemParserBridgeError.invalidResponse(error.localizedDescription) }
    }
}

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
    case complete
    case divergent
    case inconclusive
}

public struct EcosystemParserComparison: Codable, Sendable, Equatable {
    public let revision: UInt64
    public let grammarFingerprint: String
    public let sourceFingerprint: String
    public let engines: [EcosystemParserObservation]
    public let agreement: EcosystemParserAgreement

    public init(revision: UInt64, grammarFingerprint: String,
                sourceFingerprint: String,
                engines: [EcosystemParserObservation]) {
        self.revision = revision
        self.grammarFingerprint = grammarFingerprint
        self.sourceFingerprint = sourceFingerprint
        self.engines = engines
        let supported = engines.filter(\.supported)
        if supported.count < 2 {
            agreement = .inconclusive
        } else {
            agreement = Set(supported.map(\.accepted)).count == 1
                ? .complete : .divergent
        }
    }
}

public actor PL0EcosystemParserSession {
    private let transport: any EcosystemParserTransport
    private let languageKit: PL0LanguageKit

    public init(transport: any EcosystemParserTransport,
                languageKit: PL0LanguageKit = .bundled) {
        self.transport = transport
        self.languageKit = languageKit
    }

    public func compare(_ snapshot: SourceSnapshot) async throws -> EcosystemParserComparison {
        let lexed = PL0Lexer(languageKit: languageKit).tokenize(snapshot)
        let corpus = try makeCorpus(snapshot: snapshot, tokens: lexed.tokens)
        let response = try await transport.evaluate(corpus)
        let observations: [WireObservation]
        do { observations = try JSONDecoder().decode([WireObservation].self, from: response) }
        catch { throw EcosystemParserBridgeError.invalidResponse(error.localizedDescription) }
        guard observations.count == 1, observations[0].id == "modedit-pl0" else {
            throw EcosystemParserBridgeError.invalidResponse("missing modedit-pl0 observation")
        }
        let engines = observations[0].engines ?? []
        guard engines.map(\.parser) == EcosystemParserEngine.allCases else {
            throw EcosystemParserBridgeError.invalidResponse(
                "engine order or membership differs from the canonical ten-engine set")
        }
        return EcosystemParserComparison(
            revision: snapshot.version,
            grammarFingerprint: languageKit.artifact.fingerprint,
            sourceFingerprint: StableFingerprint.fnv1a64(snapshot.text),
            engines: engines)
    }

    private func makeCorpus(snapshot: SourceSnapshot,
                            tokens: [PL0Token]) throws -> Data {
        let artifact = languageKit.artifact
        let grammar = WireGrammar(
            id: "pl0-\(artifact.fingerprint)", start: artifact.startSymbol,
            terminals: artifact.tokenDefinitions.map(\.name), precedence: [],
            productions: artifact.productions.map { production in
                WireProduction(
                    id: production.id, lhs: production.lhs,
                    rhs: production.rhs.map { symbol in
                        switch symbol {
                        case .terminal(let name, _): name
                        case .nonterminal(let name): name
                        }
                    })
            })
        let significant = tokens.filter { $0.kind != .endOfFile }.map { $0.kind.grammarName }
        let corpus = WireCorpus(
            schemaVersion: 5, grammars: [grammar],
            cases: [WireCase(
                id: "modedit-pl0", grammar: grammar.id, input: snapshot.text,
                expectedTokenKinds: significant,
                expectedStatus: "accepted", tags: ["engine-comparison"])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(corpus)
    }
}

private struct WireCorpus: Encodable {
    let schemaVersion: Int
    let grammars: [WireGrammar]
    let cases: [WireCase]
}

private struct WireGrammar: Encodable {
    let id: String
    let start: String
    let terminals: [String]
    let precedence: [String]
    let productions: [WireProduction]
}

private struct WireProduction: Encodable {
    let id: String
    let lhs: String
    let rhs: [String]
}

private struct WireCase: Encodable {
    let id: String
    let grammar: String
    let input: String
    let expectedTokenKinds: [String]
    let expectedStatus: String
    let tags: [String]
}

private struct WireObservation: Decodable {
    let id: String
    let engines: [EcosystemParserObservation]?
}
