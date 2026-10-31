import Foundation
import Testing
@testable import PL0Language

@Suite("PL/0 ecosystem parser bridge")
struct EcosystemParserBridgeTests {
    @Test func sendsAuthoritativeGrammarAndSignificantTokensToAllEngines() async throws {
        let transport = MockEcosystemTransport()
        let session = PL0EcosystemParserSession(transport: transport)
        let comparison = try await session.compare(
            SourceSnapshot(version: 9, text: "var x; begin x := 1 end."))

        #expect(comparison.revision == 9)
        #expect(comparison.grammarFingerprint == PL0LanguageKit.bundled.artifact.fingerprint)
        #expect(comparison.engines.map(\.parser) == EcosystemParserEngine.allCases)
        #expect(comparison.engines.allSatisfy { $0.accepted })
        #expect(comparison.agreement == .complete)

        let request = try #require(await transport.request())
        #expect(request.schemaVersion == 5)
        #expect(request.productionCount == 43)
        #expect(request.terminalCount == 29)
        #expect(request.tokenKinds.prefix(3) == ["VAR", "IDENTIFIER", "SEMICOLON"])
        #expect(!request.tokenKinds.contains("endOfFile"))
    }

    @Test func disagreementIsRetainedInsteadOfNormalizedAway() async throws {
        let transport = MockEcosystemTransport(rejected: .lr0)
        let comparison = try await PL0EcosystemParserSession(
            transport: transport).compare(SourceSnapshot(version: 1, text: "."))

        #expect(comparison.agreement == .divergent)
        #expect(comparison.engines.first { $0.parser == .lr0 }?.accepted == false)
    }

    @Test func realGrammarREPLRunsCanonicalEngineFamilyWhenConfigured() async throws {
        guard let path = ProcessInfo.processInfo.environment[
            "MODEDIT_TEST_GRAMMAR_REPL_CONFORMANCE"] else { return }
        let transport = GrammarREPLConformanceProcessTransport(
            executableURL: URL(fileURLWithPath: path))
        let comparison = try await PL0EcosystemParserSession(
            transport: transport).compare(
                SourceSnapshot(version: 1, text: "var x; begin x := 1 end."))

        #expect(comparison.engines.count == 10)
        #expect(comparison.engines.allSatisfy { $0.supported })
        #expect(comparison.engines.filter(\.accepted).map(\.parser) == [
            .earley, .earleySL, .earleyEL, .rnglr, .ll1, .slr, .lalr, .lr1,
        ])
        #expect(comparison.engines.filter { !$0.accepted }.map(\.parser) == [.cyk, .lr0])
        #expect(comparison.agreement == .divergent)
        #expect(comparison.engines.filter { $0.forestNodes != nil }.count == 4)
    }
}

private actor MockEcosystemTransport: EcosystemParserTransport {
    private let rejected: EcosystemParserEngine?
    private var captured: MockRequest?

    init(rejected: EcosystemParserEngine? = nil) {
        self.rejected = rejected
    }

    func evaluate(_ corpus: Data) async throws -> Data {
        let object = try #require(
            JSONSerialization.jsonObject(with: corpus) as? [String: Any])
        let grammar = try #require((object["grammars"] as? [[String: Any]])?.first)
        let testCase = try #require((object["cases"] as? [[String: Any]])?.first)
        captured = MockRequest(
            schemaVersion: object["schemaVersion"] as? Int ?? 0,
            productionCount: (grammar["productions"] as? [[String: Any]])?.count ?? 0,
            terminalCount: (grammar["terminals"] as? [String])?.count ?? 0,
            tokenKinds: testCase["expectedTokenKinds"] as? [String] ?? [])

        let engines: [[String: Any]] = EcosystemParserEngine.allCases.map { engine in
            let accepted = engine != rejected
            return [
                "parser": engine.rawValue,
                "status": accepted ? "accepted" : "rejected",
                "derivations": accepted ? 1 : 0,
                "forestNodes": NSNull(),
                "ambiguous": false,
                "productionIdentified": false,
                "replayEvents": accepted ? ["start", "accept"] : ["start", "reject"],
                "supported": true,
                "unsupportedReason": NSNull(),
            ]
        }
        return try JSONSerialization.data(withJSONObject: [[
            "id": "modedit-pl0", "status": "accepted", "root": "Program",
            "diagnostics": 0, "recoveryEdits": [], "engines": engines,
        ]])
    }

    func request() -> MockRequest? { captured }
}

private struct MockRequest: Sendable {
    let schemaVersion: Int
    let productionCount: Int
    let terminalCount: Int
    let tokenKinds: [String]
}
