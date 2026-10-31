import Foundation
import Testing
@testable import PL0Language

@Suite("PL/0 direct ecosystem parser integration")
struct EcosystemParserBridgeTests {
    @Test func runsCanonicalLinkedEngineFamily() async throws {
        let comparison = try await PL0EcosystemParserSession().compare(
            SourceSnapshot(version: 9, text: "var x; begin x := 1 end."))

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
        let comparison = try await PL0EcosystemParserSession().compare(
            SourceSnapshot(version: 3, text: "."))
        let encoded = try JSONEncoder().encode(comparison)
        #expect(try JSONDecoder().decode(
            EcosystemParserComparison.self, from: encoded) == comparison)
    }
}
