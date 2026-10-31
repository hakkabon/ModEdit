import Foundation
import Testing
@testable import LanguageExperimentProtocol

@Suite("Language experiment protocol")
struct LanguageExperimentProtocolTests {
    @Test func bundleRoundTripsWithDeterministicJSON() throws {
        let run = try makeRun()
        let bundle = try LanguageExperimentBundle(
            id: "edit-sequence", title: "PL/0 edit sequence", runs: [run],
            metadata: ["producer": "test"])

        let first = try bundle.json()
        let decoded = try LanguageExperimentBundle.decode(json: first)
        let second = try decoded.json()

        #expect(decoded == bundle)
        #expect(first == second)
        #expect(String(decoding: first, as: UTF8.self).contains("\"schemaVersion\" : 1"))
    }

    @Test func decoderRejectsUnknownSchema() throws {
        let bundle = try LanguageExperimentBundle(
            id: "one", title: "One", runs: [makeRun()])
        let json = String(decoding: try bundle.json(), as: UTF8.self)
            .replacingOccurrences(of: "\"schemaVersion\" : 1",
                                  with: "\"schemaVersion\" : 99",
                                  options: [], range: nil)

        #expect(throws: ExperimentContractError.unsupportedSchema(99)) {
            try LanguageExperimentBundle.decode(json: Data(json.utf8))
        }
    }

    @Test func decoderRevalidatesNestedSourceEvidence() throws {
        let bundle = try LanguageExperimentBundle(
            id: "one", title: "One", runs: [makeRun()])
        let validFingerprint = StableFingerprint.fnv1a64("x.")
        let json = String(decoding: try bundle.json(), as: UTF8.self)
            .replacingOccurrences(of: validFingerprint,
                                  with: "0000000000000000")

        #expect(throws: ExperimentContractError.mismatchedSourceFingerprint) {
            try LanguageExperimentBundle.decode(json: Data(json.utf8))
        }
    }

    @Test func tokenIdentityAndRangeInvariantsAreEnforced() throws {
        let text = "x."
        let document = try makeDocument(text: text)
        let grammar = try makeGrammar()
        let token = try ExperimentToken(
            id: "same", kind: "identifier", lexeme: "x",
            range: ExperimentRange(location: 0, length: 1), channel: .source)

        #expect(throws: ExperimentContractError.duplicateTokenID("same")) {
            try TokenSnapshot(document: document, grammar: grammar,
                              tokens: [token, token])
        }
    }

    @Test func reuseDimensionsRemainIndependent() throws {
        let evidence = try ReuseEvidence(
            incremental: true, baseRevision: 6,
            measurements: [
                ReuseMeasurement(dimension: .syntaxNodes, reused: 4,
                                 rebuilt: 2, strategy: "subtree-cache"),
                ReuseMeasurement(dimension: .tokens, reused: 9,
                                 rebuilt: 1, strategy: "convergence"),
            ])

        #expect(evidence.measurements.map(\.dimension) == [.syntaxNodes, .tokens])
        #expect(evidence.measurements[0].reused == 4)
        #expect(evidence.measurements[1].reused == 9)
    }

    private func makeRun() throws -> ParseExperimentRun {
        let text = "x."
        let document = try makeDocument(text: text)
        let source = try SourceArtifact(document: document, text: text)
        let grammar = try makeGrammar()
        let token = try ExperimentToken(
            id: "t0", kind: "identifier", lexeme: "x",
            range: ExperimentRange(location: 0, length: 1), channel: .source)
        let tokens = try TokenSnapshot(document: document, grammar: grammar,
                                       tokens: [token])
        let engine = try ExperimentEngineIdentity(
            id: "reference", displayName: "Reference", algorithm: "LL",
            implementation: "tests")
        return try ParseExperimentRun(
            id: "run-7", source: source, grammar: grammar,
            tokenSnapshot: tokens,
            execution: EngineExecutionPath(requested: engine, effective: engine),
            disposition: .completed, status: .accepted, diagnostics: [],
            recovery: RecoveryEvidence(edits: []),
            reuse: ReuseEvidence(incremental: false, baseRevision: nil,
                                 measurements: []),
            syntaxFingerprint: StableFingerprint.fnv1a64("Program"))
    }

    private func makeDocument(text: String) throws -> DocumentRevision {
        try DocumentRevision(
            uri: "file:///test.pl0", languageID: "pl0", revision: 7,
            coordinateSpace: .utf16, sourceLength: text.utf16.count,
            sourceFingerprint: StableFingerprint.fnv1a64(text))
    }

    private func makeGrammar() throws -> GrammarArtifactIdentity {
        try .sourceArtifact(id: "pl0", languageID: "pl0", revision: 1,
                            notation: "BNF", source: "Program ::= identifier '.'")
    }
}
