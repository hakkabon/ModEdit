import Foundation
import Testing
@testable import PL0Language

@Suite("PL/0 LSP adapter")
struct PL0LSPAdapterTests {
    private let uri = "file:///test/example.pl0"

    @Test func mapsUTF16PositionsIncludingEmojiAndCRLF() {
        let map = LSPLineMap("😀x\r\ny")
        #expect(map.offset(of: LSPPosition(line: 0, character: 2)) == 2)
        #expect(map.offset(of: LSPPosition(line: 1, character: 1)) == 6)
        #expect(map.offset(of: LSPPosition(line: 0, character: 4)) == nil)
        #expect(map.position(of: 5) == LSPPosition(line: 1, character: 0))
    }

    @Test func publishesParserAndSemanticDiagnostics() async throws {
        let adapter = PL0LSPAdapter()
        let diagnostics = await adapter.open(
            uri: uri, version: 1, text: "var x; begin y := 1 end.")
        #expect(diagnostics.contains { $0.source == "pl0-semantics" && $0.message.contains("Unknown identifier 'y'") })
        #expect(diagnostics.first { $0.message.contains("Unknown identifier") }?.range.start
                == LSPPosition(line: 0, character: 13))
    }

    @Test func appliesIncrementalChangesAndRejectsStaleVersions() async throws {
        let adapter = PL0LSPAdapter()
        _ = await adapter.open(uri: uri, version: 4, text: "var x; begin x := 1 end.")
        let change = LSPTextChange(
            range: LSPRange(start: LSPPosition(line: 0, character: 18),
                            end: LSPPosition(line: 0, character: 19)), text: "42")
        let diagnostics = try await adapter.change(uri: uri, version: 5, changes: [change])
        #expect(diagnostics.isEmpty)
        #expect(try await adapter.snapshot(uri: uri).text.contains("42"))
        await #expect(throws: PL0LSPError.self) {
            try await adapter.change(uri: uri, version: 5, changes: [])
        }
    }

    @Test func completionObservesNestedScopesAndShadowing() async throws {
        let source = "const limit = 3; var x; procedure p; var local; begin local := x end; begin call p end."
        let adapter = PL0LSPAdapter()
        _ = await adapter.open(uri: uri, version: 1, text: source)
        let inside = try await adapter.completions(
            uri: uri, at: LSPLineMap(source).position(of: (source as NSString).range(of: "local :=").location))
        #expect(inside.contains { $0.label == "local" && $0.kind == .variable })
        #expect(inside.contains { $0.label == "x" && $0.kind == .variable })
        #expect(inside.contains { $0.label == "limit" && $0.kind == .constant })
        let outside = try await adapter.completions(
            uri: uri, at: LSPLineMap(source).position(of: (source as NSString).range(of: "call p").location))
        #expect(!outside.contains { $0.label == "local" })
        #expect(outside.contains { $0.label == "p" && $0.kind == .function })
    }

    @Test func definitionResolvesAcrossLexicalParentsCaseInsensitively() async throws {
        let source = "var Value; procedure p; begin value := 1 end; begin call p end."
        let adapter = PL0LSPAdapter()
        _ = await adapter.open(uri: uri, version: 1, text: source)
        let use = (source as NSString).range(of: "value :=").location + 2
        let location = try await adapter.definition(
            uri: uri, at: LSPLineMap(source).position(of: use))
        #expect(location?.uri == uri)
        #expect(location?.range == LSPRange(
            start: LSPPosition(line: 0, character: 4),
            end: LSPPosition(line: 0, character: 9)))
    }

    @Test func semanticTokensDistinguishDeclarationsAndReferences() async throws {
        let source = "const n = 2; var x; begin x := n end."
        let adapter = PL0LSPAdapter()
        _ = await adapter.open(uri: uri, version: 1, text: source)
        let tokens = try await adapter.semanticTokens(uri: uri)
        #expect(tokens.contains { $0.type == .constant && $0.isDeclaration })
        #expect(tokens.contains { $0.type == .constant && !$0.isDeclaration })
        #expect(tokens.contains { $0.type == .variable && $0.isDeclaration })
        #expect(tokens.contains { $0.type == .variable && !$0.isDeclaration })
        #expect(tokens.contains { $0.type == .keyword })
        #expect(tokens.contains { $0.type == .operatorToken })

        let encoded = try await adapter.semanticTokenData(uri: uri)
        #expect(encoded.data.count == tokens.count * 5)
        #expect(encoded.data.enumerated().allSatisfy {
            $0.offset % 5 != 2 || $0.element > 0
        })
        #expect(encoded.resultID.hasPrefix("1:"))
    }

    @Test func hoverAndReferencesUseSharedSymbolIdentity() async throws {
        let source = "const n = 2; var x; begin x := n + n end."
        let adapter = PL0LSPAdapter()
        _ = await adapter.open(uri: uri, version: 1, text: source)
        let use = (source as NSString).range(of: "n + n").location
        let position = LSPLineMap(source).position(of: use)

        let hover = try await adapter.hover(uri: uri, at: position)
        let references = try await adapter.references(uri: uri, at: position)

        #expect(hover?.contents == "constant n = 2")
        #expect(references.count == 3)
        #expect(references.first?.range.start == LSPPosition(line: 0, character: 6))
    }

    @Test func closeReleasesDocumentState() async throws {
        let adapter = PL0LSPAdapter()
        _ = await adapter.open(uri: uri, version: 1, text: ".")
        await adapter.close(uri: uri)
        await #expect(throws: PL0LSPError.self) {
            try await adapter.diagnostics(uri: uri)
        }
    }
}
