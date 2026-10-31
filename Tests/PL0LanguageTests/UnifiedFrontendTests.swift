import Testing
@testable import PL0Language

@Suite("Unified PL/0 experimental front end")
struct UnifiedFrontendTests {
    @Test func preparedInputFeedsEveryLocalEngine() {
        let snapshot = SourceSnapshot(
            version: 17, text: "var x; begin x := 1 end.")
        let sourceFrontend = PL0Frontend()
        let prepared = sourceFrontend.prepare(snapshot)

        #expect(prepared.snapshot == snapshot)
        #expect(prepared.input.source == snapshot.text)
        #expect(prepared.input.tokens.map(\.id) == prepared.lexed.tokens.map(\.id))
        #expect(prepared.grammarFingerprint
                == PL0LanguageKit.bundled.artifact.fingerprint)

        for engine in ParserEngine.allCases {
            let result = PL0Frontend(engine: engine).parse(prepared)
            #expect(result.version == snapshot.version)
            #expect(result.tokens.map(\.id) == prepared.lexed.tokens.map(\.id))
        }
    }

    @Test func consumersUseTheInjectedLanguageKit() async throws {
        let grammar = PL0LanguageKit.bundled.artifact.source.replacingOccurrences(
            of: "%token BEGIN /begin\\b/", with: "%token BEGIN /start\\b/")
        let kit = try PL0LanguageKit.compile(
            source: grammar, revision: 2, artifactID: "test.pl0.start")
        let frontend = PL0Frontend(languageKit: kit)
        let source = "start end."

        #expect(PL0Frontend().parse(
            SourceSnapshot(version: 1, text: source)).diagnostics.isEmpty == false)
        #expect(try PL0Formatter(frontend: frontend).format(source) == "start\nend.\n")
        _ = try PL0Compiler(frontend: frontend).compile(
            SourceSnapshot(version: 1, text: source))

        let diagnostics = await PL0LSPAdapter(frontend: frontend).open(
            uri: "file:///custom.pl0", version: 1, text: source)
        #expect(diagnostics.isEmpty)
    }
}
