import Foundation
import Testing
@testable import PL0Language

@Suite("PL/0 shared semantics, compiler, and LSP")
struct SemanticsCompilerLSPTests {
    @Test func semanticModelOwnsScopesSlotsAndResolution() async {
        let source = "const limit = 3; var x; procedure p; var local; begin local := x end; begin x := limit; call p end."
        let analysis = await PL0LanguageSession().analyze(
            SourceSnapshot(version: 7, text: source))

        let limit = analysis.semantics.symbols.first { $0.name == "limit" }
        let x = analysis.semantics.symbols.first { $0.name == "x" }
        let local = analysis.semantics.symbols.first { $0.name == "local" }
        let procedure = analysis.semantics.symbols.first { $0.name == "p" }

        #expect(limit?.kind == .constant)
        #expect(limit?.constantValue == 3)
        #expect(x?.slot == 0)
        #expect(x?.lexicalLevel == 0)
        #expect(local?.slot == 0)
        #expect(local?.lexicalLevel == 1)
        #expect(procedure?.kind == .procedure)
        #expect(analysis.semantics.scopes.count == 2)
        #expect(analysis.semantics.references.count == 5)
        #expect(analysis.semantics.diagnostics.isEmpty)
    }

    @Test func semanticDiagnosticsAreSharedByCompilerAndLSP() async throws {
        let source = "const c = 1; var x, x; procedure p; ; begin c := p; call x; y := 1 end."
        let uri = "file:///shared-semantics.pl0"
        let adapter = PL0LSPAdapter()
        let lspDiagnostics = await adapter.open(uri: uri, version: 1, text: source)
        let analysis = try await adapter.analysis(uri: uri)

        #expect(analysis.semantics.diagnostics.contains {
            $0.message.contains("Duplicate declaration")
        })
        #expect(analysis.semantics.diagnostics.contains {
            $0.message.contains("not a variable")
        })
        #expect(analysis.semantics.diagnostics.contains {
            $0.message.contains("Unknown identifier 'y'")
        })
        #expect(lspDiagnostics.filter { $0.source == "pl0-semantics" }.count
                == analysis.semantics.diagnostics.count)
        #expect(throws: PL0CompilationError.self) {
            _ = try PL0Compiler().compile(analysis)
        }
    }

    @Test func rangedLSPChangeRetainsIncrementalSemanticIdentity() async throws {
        let source = "var value; begin value := 1 end."
        let uri = "file:///incremental-semantics.pl0"
        let adapter = PL0LSPAdapter()
        _ = await adapter.open(uri: uri, version: 1, text: source)
        let first = try await adapter.analysis(uri: uri)
        let firstID = try #require(
            first.semantics.symbols.first { $0.name == "value" }?.id)
        let number = (source as NSString).range(of: "1")
        let map = LSPLineMap(source)

        _ = try await adapter.change(
            uri: uri, version: 2,
            changes: [LSPTextChange(
                range: LSPRange(start: map.position(of: number.location),
                                end: map.position(of: number.location + number.length)),
                text: "2")])
        let second = try await adapter.analysis(uri: uri)

        #expect(second.parse.metrics.incrementalLexing.incremental)
        #expect(second.semantics.symbols.first { $0.name == "value" }?.id == firstID)
        #expect(second.semantics.version == 2)
    }

    @Test func compilationPublishesCompilerSyntaxBoundary() async throws {
        let source = "var x; begin x := 2 + 3 end."
        let analysis = await PL0LanguageSession().analyze(
            SourceSnapshot(version: 1, text: source))
        let artifacts = try PL0Compiler().compileArtifacts(analysis)
        let execution = try PL0VirtualMachine().run(artifacts.program)

        #expect(artifacts.compilerSyntax.rule == "PL0Document")
        #expect(artifacts.compilerSyntax.children.last?.rule == "ConcreteTerminals")
        #expect(artifacts.compilerSyntax.children.last?.children.count
                == analysis.parse.syntaxTree.terminals.count)
        #expect(execution.globals.first { $0.name == "x" }?.value == 5)
    }
}
