import Foundation
import Testing
@testable import PL0Language

@Suite("PL/0 direct ecosystem parser integration")
struct EcosystemParserBridgeTests {
    @Test func runsCanonicalLinkedEngineFamily() async throws {
        let prepared = PL0Frontend().prepare(
            SourceSnapshot(version: 9, text: "var x; begin x := 1 end."))
        let comparison = try await PL0EcosystemParserSession().compare(prepared)

        #expect(comparison.revision == 9)
        #expect(comparison.grammarFingerprint
                == PL0LanguageKit.bundled.artifact.fingerprint)
        #expect(comparison.engines.map(\.parser) == EcosystemParserEngine.allCases)
        #expect(comparison.engines.allSatisfy { $0.supported })
        #expect(comparison.engines.first { $0.parser == .slr }?.accepted == true)
        #expect(comparison.engines.first { $0.parser == .earley }?.accepted == true)
        #expect(comparison.engines.first { $0.parser == .ll1 }?.accepted == true)
    }

    @Test func preservesEachRealEnginesDecision() async throws {
        let comparison = try await PL0EcosystemParserSession().compare(
            SourceSnapshot(version: 1, text: "var ; ."))

        #expect(comparison.engines.map(\.parser) == EcosystemParserEngine.allCases)
        #expect(comparison.engines.contains { !$0.accepted })
        #expect(comparison.engines.allSatisfy { !$0.replayEvents.isEmpty })
    }

    @Test func comparisonRoundTripsForExperimentStorage() async throws {
        let snapshot = SourceSnapshot(version: 3, text: ".")
        let session = PL0LanguageSession(engine: .generatedLR)
        let parsed = await session.parse(snapshot)
        let comparison = try await session.compare(snapshot)
        let formatted = try await session.format(snapshot)
        _ = try await session.compile(snapshot)
        #expect(formatted == ".\n")
        #expect(parsed.version == comparison.revision)
        #expect(parsed.grammarArtifact.fingerprint == comparison.grammarFingerprint)
        let encoded = try JSONEncoder().encode(comparison)
        #expect(try JSONDecoder().decode(
            EcosystemParserComparison.self, from: encoded) == comparison)
    }
}
