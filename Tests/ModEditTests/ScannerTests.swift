import Testing
import AppKit
import Foundation
import UniformTypeIdentifiers
@testable import ModEditCore

@Suite("Scanner protocol")
struct ScannerProtocolTests {

    @Test func shippedFormatsDeclareTheirScanners() {
        #expect(MarkdownFormat().scanner is MarkdownScanner)
        #expect(HTMLFormat().scanner is HTMLScanner)
        #expect(LaTeXFormat().scanner == nil)
        #expect(PlainTextFormat().scanner == nil)
    }

    @Test func customScannerStateCarriesAcrossChunksAndCheckpoints() throws {
        let tokenizer = try Tokenizer(rules: [], scanner: CountingScanner())
        let text = "aa\nbb\n" as NSString
        let first = text.lineRange(for: NSRange(location: 0, length: 1))
        let second = text.lineRange(for: NSRange(location: 3, length: 1))

        var state = Tokenizer.State()
        let firstTokens = tokenizer.tokens(in: text, range: first, state: &state)
        #expect(firstTokens == [Token(range: first, kind: .code)])

        // A checkpoint must capture the scanner's own state, not just the
        // tokenizer's scan offset.
        var checkpoints = Tokenizer.Checkpoints()
        checkpoints.record(state, at: state.scanLocation)
        var resumed = try #require(checkpoints.state(atOrBefore: second.location))
        let secondTokens = tokenizer.tokens(in: text, range: second, state: &resumed,
                                            checkpoints: &checkpoints)
        #expect(secondTokens.isEmpty)
    }

    @Test func scannerCanRestrictRegexMatchesToAScope() throws {
        let tokenizer = try Tokenizer(rules: [HighlightRule("needle", .strong)],
                                      scanner: EmptyScopeScanner())
        let text = "needle" as NSString
        let tokens = tokenizer.tokens(in: text,
                                      range: NSRange(location: 0, length: text.length))
        #expect(tokens.isEmpty)
    }
}

@Suite("Format registry injection", .serialized)
@MainActor
struct FormatRegistryInjectionTests {

    @Test func editorDocumentAndModelUseTheInjectedRegistry() {
        let registry = FormatRegistry(formats: [], fallback: TestFormat(id: "custom"))
        let document = EditorDocument(registry: registry)
        let model = EditorModel(document: document)

        #expect(document.currentFormat.id == "custom")
        #expect(model.registry.fallback.id == "custom")
    }

    @Test func documentReadsWithTheInjectedRegistry() throws {
        let registry = FormatRegistry(formats: [], fallback: TestFormat(id: "custom"))
        let document = ModEditDocument(registry: registry,
                                       formatStore: InMemoryFormatPreferenceStore())

        try document.read(from: Data("hello".utf8),
                          ofType: UTType.plainText.identifier)

        #expect(document.buffer.currentFormat.id == "custom")
    }
}

/// Emits a token on even-numbered chunks. If scanner state were not carried,
/// the second chunk would look like the first and emit a token again.
private struct CountingScanner: StatefulScanner {
    struct State: ScannerState, Equatable {
        var chunks = 0
    }

    func initialState() -> State { State() }

    func tokens(in text: NSString,
                from scanStart: Int,
                clippedTo requested: NSRange,
                state: inout State) -> ScannedTokens {
        let token = state.chunks.isMultiple(of: 2)
            ? Token(range: requested, kind: .code)
            : nil
        state.chunks += 1
        return ScannedTokens(trailing: token.map { [$0] } ?? [])
    }
}

/// Rejects every regex match by returning an empty rule scope.
private struct EmptyScopeScanner: StatefulScanner {
    struct State: ScannerState, Equatable {}

    func initialState() -> State { State() }

    func tokens(in text: NSString,
                from scanStart: Int,
                clippedTo requested: NSRange,
                state: inout State) -> ScannedTokens {
        ScannedTokens(ruleScope: [])
    }
}

private struct TestFormat: DocumentFormat {
    let id: String
    let displayName = "Test"
    let contentTypes: [UTType] = [.plainText]
    let fileExtensions = ["test"]
    var highlightRules: [HighlightRule] { [] }
    func makePreviewRenderer() -> (any PreviewRenderer)? { nil }
}
