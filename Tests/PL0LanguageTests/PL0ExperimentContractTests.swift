import Foundation
import LanguageExperimentProtocol
import Testing
@testable import PL0Language

@Suite("PL/0 experiment contract adapter")
struct PL0ExperimentContractTests {
    @Test func exportsCleanReferenceParse() throws {
        let snapshot = SourceSnapshot(version: 4, text: "begin call p end.")
        let result = PL0Frontend().parse(snapshot)
        let run = try result.experimentRun(
            snapshot: snapshot, documentURI: "file:///program.pl0")

        #expect(run.status == .accepted)
        #expect(run.execution.requested.id == "reference-ll")
        #expect(!run.execution.usedFallback)
        #expect(run.source.document.coordinateSpace == .utf16)
        #expect(run.tokenSnapshot.tokens.last?.channel == .endOfFile)
        #expect(run.tokenSnapshot.tokens.contains { $0.channel == .trivia })
        #expect(run.syntaxFingerprint != nil)
    }

    @Test func exposesLRFallbackInsteadOfAttributingRecoveryToLR() throws {
        let snapshot = SourceSnapshot(version: 1, text: "var x; if x < 10 x := 1.")
        let result = PL0Frontend(engine: .generatedLR).parse(snapshot)
        let run = try result.experimentRun(
            snapshot: snapshot, documentURI: "file:///broken.pl0")

        #expect(run.execution.requested.id == "slr-1")
        #expect(run.execution.effective.id == "reference-ll")
        #expect(run.execution.usedFallback)
        #expect(run.status == .recovered)
        #expect(run.recovery.edits.contains { $0.kind == .insert && $0.tokenKind == "then" })
    }

    @Test func exportsIncrementalTokenAndSyntaxReuseSeparately() async throws {
        let original = "begin a := 1; b := 2 end."
        let session = PL0LanguageSession()
        _ = await session.parse(SourceSnapshot(version: 1, text: original))
        let range = (original as NSString).range(of: "2")
        let changed = (original as NSString).replacingCharacters(in: range, with: "20")
        let snapshot = SourceSnapshot(
            version: 2, text: changed,
            edit: SourceEdit(baseVersion: 1,
                             replacedRange: SourceRange(location: range.location,
                                                        length: range.length),
                             replacementLength: 2))
        let result = await session.parse(snapshot)
        let run = try result.experimentRun(
            snapshot: snapshot, documentURI: "file:///incremental.pl0")

        #expect(run.reuse.incremental)
        #expect(run.reuse.baseRevision == 1)
        let tokenReuse = run.reuse.measurements.first { $0.dimension == .tokens }
        let syntaxReuse = run.reuse.measurements.first { $0.dimension == .syntaxNodes }
        #expect(tokenReuse?.reused ?? 0 > 0)
        #expect(syntaxReuse?.reused ?? 0 > 0)
    }

    @Test func rejectsGrammarIdentityThatDidNotProduceTheParse() throws {
        let snapshot = SourceSnapshot(version: 1, text: ".")
        let result = PL0Frontend().parse(snapshot)
        let other = try PL0ExperimentContract.grammarArtifact(
            source: PL0LanguageKit.bundled.artifact.source + "\n")

        #expect(throws: PL0LanguageKitError.self) {
            try result.experimentRun(snapshot: snapshot,
                                     documentURI: "file:///mismatch.pl0",
                                     grammar: other)
        }
    }
}
