import Foundation
import Testing
@testable import PL0Language

@Suite("PL/0 fine-grained incrementality")
struct FineGrainedIncrementalityTests {
    @Test func unrelatedLiteralEditReusesAllDeclarationsAndBindings() async throws {
        let original = "const limit = 3; var x, y; begin x := limit; y := x + 1 end."
        let session = PL0LanguageSession()
        _ = await session.analyze(SourceSnapshot(version: 1, text: original))

        let editRange = (original as NSString).range(of: "1", options: .backwards)
        let changed = (original as NSString).replacingCharacters(
            in: editRange, with: "2")
        let incremental = await session.analyze(snapshot(
            version: 2, text: changed, baseVersion: 1, range: editRange,
            replacementLength: 1))
        let fresh = freshAnalysis(version: 2, text: changed)
        let metrics = incremental.semantics.reuseMetrics

        #expect(metrics.incremental)
        #expect(metrics.baseVersion == 1)
        #expect(metrics.reusedSymbolCount == 3)
        #expect(metrics.rebuiltSymbolCount == 0)
        #expect(metrics.reusedReferenceCount == 4)
        #expect(metrics.rebuiltReferenceCount == 0)
        #expect(metrics.dependencyInvalidationCount == 0)
        try expectEquivalent(incremental, fresh)
    }

    @Test func constantEditInvalidatesOnlyItsDeclarationAndDependentUse() async throws {
        let original = "const limit = 3; var x, y; begin x := limit; y := x + 1 end."
        let session = PL0LanguageSession()
        _ = await session.analyze(SourceSnapshot(version: 1, text: original))

        let editRange = (original as NSString).range(of: "3")
        let changed = (original as NSString).replacingCharacters(
            in: editRange, with: "4")
        let incremental = await session.analyze(snapshot(
            version: 2, text: changed, baseVersion: 1, range: editRange,
            replacementLength: 1))
        let fresh = freshAnalysis(version: 2, text: changed)
        let metrics = incremental.semantics.reuseMetrics

        #expect(metrics.incremental)
        #expect(metrics.reusedSymbolCount == 2)
        #expect(metrics.rebuiltSymbolCount == 1)
        #expect(metrics.reusedReferenceCount == 3)
        #expect(metrics.rebuiltReferenceCount == 1)
        #expect(metrics.dependencyInvalidationCount == 2)
        try expectEquivalent(incremental, fresh)
    }

    @Test func nearerShadowInvalidatesOnlyReferencesToThatName() async throws {
        let original = "var x, y; procedure p; begin y := x end; begin x := 1; call p end."
        let session = PL0LanguageSession()
        _ = await session.analyze(SourceSnapshot(version: 1, text: original))

        let location = (original as NSString).range(of: "begin y").location
        let insertion = "var x; "
        let range = NSRange(location: location, length: 0)
        let changed = (original as NSString).replacingCharacters(
            in: range, with: insertion)
        let incremental = await session.analyze(snapshot(
            version: 2, text: changed, baseVersion: 1, range: range,
            replacementLength: insertion.utf16.count))
        let fresh = freshAnalysis(version: 2, text: changed)
        let metrics = incremental.semantics.reuseMetrics

        #expect(metrics.reusedSymbolCount == 3)
        #expect(metrics.rebuiltSymbolCount == 1)
        #expect(metrics.reusedReferenceCount == 3)
        #expect(metrics.rebuiltReferenceCount == 1)
        #expect(metrics.dependencyInvalidationCount == 1)
        try expectEquivalent(incremental, fresh)
    }

    @Test func editCampaignAlwaysMatchesFreshSemanticsAndBytecode() async throws {
        var text = "const limit = 1; var x, y; begin x := limit + 1; y := x + 1 end."
        let session = PL0LanguageSession()
        _ = await session.analyze(SourceSnapshot(version: 1, text: text))

        for version in UInt64(2)...12 {
            let oldValue = String((Int(version) - 2) % 8 + 1)
            let newValue = String((Int(version) - 1) % 8 + 1)
            let range = (text as NSString).range(of: oldValue, options: .backwards)
            #expect(range.location != NSNotFound)
            text = (text as NSString).replacingCharacters(in: range, with: newValue)
            let incremental = await session.analyze(snapshot(
                version: version, text: text, baseVersion: version - 1,
                range: range, replacementLength: newValue.utf16.count))
            let fresh = freshAnalysis(version: version, text: text)

            #expect(incremental.semantics.reuseMetrics.incremental)
            #expect(incremental.semantics.reuseMetrics.reusedReferenceCount > 0)
            try expectEquivalent(incremental, fresh)
        }
    }

    private func snapshot(version: UInt64, text: String, baseVersion: UInt64,
                          range: NSRange, replacementLength: Int) -> SourceSnapshot {
        SourceSnapshot(
            version: version, text: text,
            edit: SourceEdit(
                baseVersion: baseVersion,
                replacedRange: SourceRange(location: range.location,
                                           length: range.length),
                replacementLength: replacementLength))
    }

    private func freshAnalysis(version: UInt64, text: String) -> PL0Analysis {
        let compiler = PL0Compiler()
        return compiler.analyze(PL0Frontend().prepare(
            SourceSnapshot(version: version, text: text)))
    }

    private func expectEquivalent(_ incremental: PL0Analysis,
                                  _ fresh: PL0Analysis) throws {
        #expect(semanticProjection(incremental.semantics)
                == semanticProjection(fresh.semantics))
        #expect(try PL0Compiler().compile(incremental)
                == PL0Compiler().compile(fresh))
    }

    private func semanticProjection(_ model: PL0SemanticModel) -> SemanticProjection {
        let symbolsByID = Dictionary(uniqueKeysWithValues:
            model.symbols.map { ($0.id, $0) })
        return SemanticProjection(
            symbols: model.symbols.map {
                SymbolProjection(name: $0.name, kind: $0.kind,
                                 range: $0.declarationRange,
                                 scopeID: $0.scopeID,
                                 lexicalLevel: $0.lexicalLevel,
                                 slot: $0.slot,
                                 constantValue: $0.constantValue)
            },
            references: model.references.compactMap { reference in
                symbolsByID[reference.symbolID].map {
                    ReferenceProjection(range: reference.range,
                                        targetName: $0.name,
                                        targetKind: $0.kind,
                                        targetRange: $0.declarationRange)
                }
            },
            scopes: model.scopes.map {
                ScopeProjection(parentID: $0.parentID, range: $0.range,
                                symbolNames: $0.symbolIDs.compactMap {
                                    symbolsByID[$0]?.name
                                })
            },
            semanticTokens: model.semanticTokens,
            diagnostics: model.diagnostics)
    }
}

private struct SemanticProjection: Equatable {
    let symbols: [SymbolProjection]
    let references: [ReferenceProjection]
    let scopes: [ScopeProjection]
    let semanticTokens: [PL0SemanticToken]
    let diagnostics: [ParseDiagnostic]
}

private struct SymbolProjection: Equatable {
    let name: String
    let kind: PL0SymbolKind
    let range: SourceRange
    let scopeID: Int
    let lexicalLevel: Int
    let slot: Int?
    let constantValue: Int?
}

private struct ReferenceProjection: Equatable {
    let range: SourceRange
    let targetName: String
    let targetKind: PL0SymbolKind
    let targetRange: SourceRange
}

private struct ScopeProjection: Equatable {
    let parentID: Int?
    let range: SourceRange
    let symbolNames: [String]
}
