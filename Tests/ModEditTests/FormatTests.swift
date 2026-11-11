import Testing
import AppKit
import IncrementalParsing
import LanguageTooling
import UniformTypeIdentifiers
@testable import ModEditCore

@Suite("FormatRegistry")
struct FormatRegistryTests {
    let registry = FormatRegistry.standard

    @Test func exactMatchesPickTheirOwnFormat() {
        #expect(registry.format(for: .markdownText).id == "markdown")
        #expect(registry.format(for: .latex).id == "latex")
        #expect(registry.format(for: .html).id == "html")
        #expect(registry.format(for: .json).id == "json")
        #expect(registry.format(for: .cssText).id == "css")
        #expect(registry.format(for: .dotSource).id == "dot")
        #expect(registry.format(for: .pl0Source).id == "pl0")
        #expect(registry.format(for: .plainText).id == "plaintext")
    }

    @Test func unknownTypesFallBackToPlainText() {
        #expect(registry.format(for: .yaml).id == "plaintext")
    }

    @Test func idsAreUnique() {
        let ids = registry.allFormats.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func lookupByID() {
        #expect(registry.format(withID: "latex")?.displayName == "LaTeX")
        #expect(registry.format(withID: "nope") == nil)
    }

    @Test func bundledAndExternalProvidersShareOneRegistry() {
        #expect(registry.provider(withID: "pl0")?.descriptor.distribution
                == .externalLanguageKit)
        for id in [
            "html", "markdown", "latex", "json", "grammar", "dot", "css",
        ] {
            #expect(registry.provider(withID: id)?.descriptor.distribution
                    == .bundledPermanent)
        }
        #expect(registry.allProviders.map(\.descriptor.id)
                == registry.allFormats.map(\.id))
    }

    @Test func bundledAndLanguageKitSessionsShareOneAnalysisAPI() async throws {
        let markdown = try #require(registry.provider(withID: "markdown"))
        let markdownResult = try await markdown.makeSession().analyze(
            IncrementalParsing.SourceSnapshot(
                text: "# Title\n`code`", revision: .init(1)))
        #expect(markdownResult.languageID == "markdown")
        #expect(markdownResult.evidence(for: "highlighting")?.strategy == .full)
        #expect(markdownResult.tokens.contains { $0.classification == "heading" })

        let pl0 = try #require(registry.provider(withID: "pl0"))
        let pl0Result = try await pl0.makeSession().analyze(
            IncrementalParsing.SourceSnapshot(
                text: "var x; begin x := 1 end.", revision: .init(1)))
        #expect(pl0Result.languageID == "pl0")
        #expect(pl0Result.artifact != nil)
        #expect(pl0Result.evidence(for: "lexing") != nil)
        #expect(pl0Result.evidence(for: "parsing") != nil)
        #expect(pl0Result.evidence(for: "semantics") != nil)
    }

    @Test func bundledAndExternalProvidersShareToolingDocumentLifecycle() async throws {
        for id in [
            "markdown", "html", "latex", "json", "grammar", "dot", "css", "pl0",
        ] {
            let provider = try #require(registry.provider(withID: id))
            let document = LanguageToolingDocument(provider: provider)
            let source = switch id {
            case "pl0": "var x; begin x := 1 end."
            case "html": "<p title=\"x\">text</p>"
            case "latex": "\\section{Title}"
            case "json": #"{"name": true}"#
            case "grammar": #"<value> ::= "true" ;"#
            case "dot": "digraph G { a -> b; }"
            case "css": "body { color: red; }"
            default: "# Title\n`code`"
            }
            _ = try await document.open(.init(
                text: source, revision: .init(1)))
            let tokens = try await document.semanticTokens()
            #expect(tokens.data.count.isMultiple(of: 5))
            #expect(!tokens.data.isEmpty)
        }

        let html = try #require(registry.provider(withID: "html"))
        let multiline = LanguageToolingDocument(provider: html)
        _ = try await multiline.open(.init(
            text: "<!-- one\n two -->", revision: .init(1)))
        #expect(try await multiline.semanticTokens().data.count == 10)
    }

    @Test func htmlRoutesCSSAndJSONThroughEmbeddedProviders() async throws {
        let html = try #require(registry.provider(withID: "html"))
        let source = """
        <style>body { color red; }</style>
        <script type="application/json">{"name": true,}</script>
        """
        let result = try await html.makeSession().analyze(.init(
            text: source, revision: .init(1)))

        #expect(result.embeddedRegions.map(\.languageID) == ["css", "json"])
        #expect(result.diagnostics.contains {
            $0.message.contains("[css]") && $0.expected.contains(":")
        })
        #expect(result.diagnostics.contains {
            $0.message.contains("[json]") && $0.message.contains("Trailing comma")
        })
        #expect(result.tokens.contains {
            $0.modifiers.contains("embedded.css")
        })
        #expect(result.recoveryEdits.contains { edit in
            if case .insert(let terminal, let offset) = edit.action {
                return terminal == ":" && offset == (source as NSString).range(of: "red").location + 3
            }
            return false
        })
        #expect(result.recoveryEdits.allSatisfy {
            $0.diagnosticID?.hasPrefix("embedded.") ?? true
        })
    }

    @Test func markdownFenceRetainsIncrementalChildSession() async throws {
        let markdown = try #require(registry.provider(withID: "markdown"))
        let session = markdown.makeSession()
        let first = IncrementalParsing.SourceSnapshot(
            text: "before\n```json\n{\"value\": 1}\n```\nafter",
            revision: .init(1))
        let initial = try await session.analyze(first)
        #expect(initial.embeddedRegions.map(\.languageID) == ["json"])

        let location = (first.text as NSString).range(of: "1").location
        let change = try SourceEdit(
            baseRevision: first.revision,
            range: .init(location: location, length: 1), replacement: "2")
            .applying(to: first)
        let updated = try await session.analyze(change.after, change: change)
        #expect(updated.evidence(for: "embedding")?.strategy == .incremental)
        #expect(updated.evidence(
            for: "embedded.markdown.json.0.lexing")?.strategy == .incremental)
    }
}

@Suite("Highlighting")
struct HighlightingTests {

    @Test func everyShippedRuleCompiles() throws {
        for format in FormatRegistry.standard.allFormats {
            _ = try Tokenizer(rules: format.highlightRules, scanner: format.scanner)
        }
    }

    @Test func invalidPatternThrows() {
        #expect(throws: (any Error).self) {
            _ = try Tokenizer(rules: [HighlightRule("(", .code)])
        }
    }

    @Test func markdownTokens() throws {
        let format = MarkdownFormat()
        let tokenizer = try Tokenizer(rules: format.highlightRules, scanner: format.scanner)
        let text = "# Title\n`code`"
        let tokens = tokenizer.tokens(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        #expect(tokens.contains(Token(range: NSRange(location: 0, length: 7), kind: .heading)))
        #expect(tokens.contains(Token(range: NSRange(location: 8, length: 6), kind: .code)))
    }

    @Test func multilineMarkdownFenceIsOpaque() throws {
        let format = MarkdownFormat()
        let tokenizer = try Tokenizer(rules: format.highlightRules, scanner: format.scanner)
        let text = "before\n```swift\n# not a heading\n```\nafter"
        let ns = text as NSString
        let inside = ns.range(of: "# not a heading")
        let tokens = tokenizer.tokens(in: text, range: NSRange(location: 0, length: ns.length))
        #expect(tokens.contains { $0.kind == .code && NSLocationInRange(inside.location, $0.range) })
        // The heading regex may also match, but the later opaque code token wins.
        #expect(tokens.last { NSLocationInRange(inside.location, $0.range) }?.kind == .code)
    }

    @Test func multilineHTMLStatesHandleQuotedGreaterThanAndComments() throws {
        let format = HTMLFormat()
        let tokenizer = try Tokenizer(rules: format.highlightRules, scanner: format.scanner)
        let text = "<div\n title=\"a > b\">x</div>\n<!-- one\n two -->"
        let ns = text as NSString
        let tagRange = ns.range(of: "<div\n title=\"a > b\">")
        let commentRange = ns.range(of: "<!-- one\n two -->")
        let tokens = tokenizer.tokens(in: text, range: NSRange(location: 0, length: ns.length))
        #expect(tokens.contains(Token(range: tagRange, kind: .tag)))
        #expect(tokens.contains(Token(range: commentRange, kind: .comment)))
    }

    @Test func htmlAttributeNamesAreScopedToTags() throws {
        let format = HTMLFormat()
        let tokenizer = try Tokenizer(rules: format.highlightRules, scanner: format.scanner)
        let text = "outside=value <div inside=value>"
        let ns = text as NSString
        let tokens = tokenizer.tokens(in: text, range: NSRange(location: 0, length: ns.length))
        #expect(!tokens.contains(Token(range: ns.range(of: "outside"), kind: .attributeName)))
        #expect(tokens.contains(Token(range: ns.range(of: "inside"), kind: .attributeName)))
    }

    @Test func statefulTokensWorkWhenRequestedRangeStartsInsideConstruct() throws {
        let format = MarkdownFormat()
        let tokenizer = try Tokenizer(rules: format.highlightRules, scanner: format.scanner)
        let text = "```\nline one\nline two\n```"
        let ns = text as NSString
        let requested = ns.lineRange(for: ns.range(of: "line two"))
        let tokens = tokenizer.tokens(in: text, range: requested)
        #expect(tokens.contains(Token(range: requested, kind: .code)))
    }

    @Test func checkpointLookupUsesTheNearestEarlierState() throws {
        let tokenizer = try Tokenizer(rules: MarkdownFormat().highlightRules, scanner: MarkdownScanner())
        let text = "a\nb\nc\n" as NSString
        var state = Tokenizer.State()
        _ = tokenizer.tokens(in: text, range: NSRange(location: 0, length: 2), state: &state)

        var checkpoints = Tokenizer.Checkpoints()
        checkpoints.record(state, at: 2)

        #expect(checkpoints.count == 1)
        #expect(checkpoints.state(atOrBefore: 1) == nil)
        #expect(checkpoints.state(atOrBefore: 2) == state)
        #expect(checkpoints.state(atOrBefore: 100) == state)
    }

    @Test func markdownLocalPassResumesFromACheckpoint() throws {
        let tokenizer = try Tokenizer(rules: MarkdownFormat().highlightRules, scanner: MarkdownScanner())
        let text = "```\nline one\nline two\n```\n" as NSString

        // Snapshot the state after the opening fence line.
        var state = Tokenizer.State()
        _ = tokenizer.tokens(in: text,
                             range: NSRange(location: 0, length: 4),
                             state: &state)
        var checkpoints = Tokenizer.Checkpoints()
        checkpoints.record(state, at: 4)

        let requested = text.lineRange(for: text.range(of: "line two"))
        var resumed = try #require(checkpoints.state(atOrBefore: requested.location))
        let tokens = tokenizer.tokens(in: text, range: requested, state: &resumed,
                                      checkpoints: &checkpoints)

        #expect(tokens.contains(Token(range: requested, kind: .code)))
    }

    @Test func htmlLocalPassResumesWithAnOpenTag() throws {
        let tokenizer = try Tokenizer(rules: HTMLFormat().highlightRules, scanner: HTMLScanner())
        let text = "<div\n title=\"a > b\">x</div>\n" as NSString

        // Snapshot in the middle of a multi-line tag, at the line boundary.
        var state = Tokenizer.State()
        _ = tokenizer.tokens(in: text,
                             range: NSRange(location: 0, length: 5),
                             state: &state)
        var checkpoints = Tokenizer.Checkpoints()
        checkpoints.record(state, at: 5)

        let requested = text.lineRange(for: text.range(of: "title"))
        var resumed = try #require(checkpoints.state(atOrBefore: requested.location))
        let tokens = tokenizer.tokens(in: text, range: requested, state: &resumed,
                                      checkpoints: &checkpoints)

        #expect(tokens.contains {
            $0.kind == .tag && NSLocationInRange(requested.location, $0.range)
        })
        #expect(tokens.contains { $0.kind == .attributeName })
        #expect(tokens.contains { $0.kind == .string })
    }

    @Test func htmlLocalPassResumesInsideAComment() throws {
        let tokenizer = try Tokenizer(rules: HTMLFormat().highlightRules, scanner: HTMLScanner())
        let text = "<!-- one\n two -->\n<p>x</p>\n" as NSString

        var state = Tokenizer.State()
        _ = tokenizer.tokens(in: text, range: NSRange(location: 0, length: 9),
                             state: &state)
        var checkpoints = Tokenizer.Checkpoints()
        checkpoints.record(state, at: 9)

        let requested = text.lineRange(for: text.range(of: "two"))
        var resumed = try #require(checkpoints.state(atOrBefore: requested.location))
        let tokens = tokenizer.tokens(in: text, range: requested, state: &resumed,
                                      checkpoints: &checkpoints)

        #expect(tokens.contains {
            $0.kind == .comment && NSLocationInRange(requested.location, $0.range)
        })
    }

    @Test func invalidatingACheckpointDropsItAndEverythingAfterIt() {
        var checkpoints = Tokenizer.Checkpoints()
        let spacing = Tokenizer.Checkpoints.spacing
        let state = Tokenizer.State()
        checkpoints.record(state, at: 0)
        checkpoints.record(state, at: spacing)
        checkpoints.record(state, at: spacing * 2)

        checkpoints.invalidate(from: spacing)

        #expect(checkpoints.offsets == [0])
    }

    @Test func checkpointsKeepAtLeastOneSpacingBetweenNeighbours() {
        var checkpoints = Tokenizer.Checkpoints()
        let spacing = Tokenizer.Checkpoints.spacing
        let state = Tokenizer.State()

        checkpoints.record(state, at: 0)
        checkpoints.record(state, at: spacing * 2)
        // Exactly one spacing from both neighbours: allowed.
        checkpoints.record(state, at: spacing)
        // Too close to the newly inserted checkpoint: skipped, so pathological
        // descending edits cannot grow the cache without bound.
        checkpoints.record(state, at: spacing + spacing / 2)

        #expect(checkpoints.offsets == [0, spacing, spacing * 2])
    }

    @Test func markdownFullPassStateCarriesAcrossLineChunks() throws {
        let format = MarkdownFormat()
        let tokenizer = try Tokenizer(rules: format.highlightRules, scanner: format.scanner)
        let text = "intro\n```swift\n# not a heading\nlet x = 1\n```\n"
            + "middle ``` literal\nnot a fence\nafter\n"
        let ns = text as NSString
        let whole = tokenizer.tokens(in: text, range: NSRange(location: 0, length: ns.length))
        let chunked = chunkedTokens(tokenizer, text: text, chunkSize: 1)

        #expect(mergedTokens(chunked, kinds: [.code]) == mergedTokens(whole, kinds: [.code]))
        let headingLine = ns.range(of: "# not a heading")
        #expect(mergedTokens(chunked, kinds: [.code]).contains {
            NSLocationInRange(headingLine.location, $0.range)
        })
    }

    @Test func unterminatedMarkdownFenceContinuesAcrossLineChunks() throws {
        let format = MarkdownFormat()
        let tokenizer = try Tokenizer(rules: format.highlightRules, scanner: format.scanner)
        let text = "intro\n```\nstill code\nand more code\n"
        let ns = text as NSString
        let whole = tokenizer.tokens(in: text, range: NSRange(location: 0, length: ns.length))
        let chunked = chunkedTokens(tokenizer, text: text, chunkSize: 1)

        #expect(mergedTokens(chunked, kinds: [.code]) == mergedTokens(whole, kinds: [.code]))
        #expect(mergedTokens(chunked, kinds: [.code]).first
                == Token(range: NSRange(location: 6, length: ns.length - 6), kind: .code))
    }

    @Test func fenceAtScannerWindowBoundaryIsRecognised() throws {
        let format = MarkdownFormat()
        let tokenizer = try Tokenizer(rules: format.highlightRules, scanner: format.scanner)
        // Put the opening triple backticks across the scanner's 64K window edge.
        let prefix = String(repeating: "a", count: 65_534) + "\n"
        let text = prefix + "```\ncode\n```\n"
        let ns = text as NSString
        let whole = tokenizer.tokens(in: text, range: NSRange(location: 0, length: ns.length))
        let chunked = chunkedTokens(tokenizer, text: text, chunkSize: 1)

        #expect(mergedTokens(chunked, kinds: [.code]) == mergedTokens(whole, kinds: [.code]))
        #expect(mergedTokens(chunked, kinds: [.code]).first
                == Token(range: NSRange(location: 65_535, length: ns.length - 65_535),
                         kind: .code))
    }

    @Test func htmlFullPassStateCarriesAcrossLineChunks() throws {
        let format = HTMLFormat()
        let tokenizer = try Tokenizer(rules: format.highlightRules, scanner: format.scanner)
        let text = "<div\n title=\"a > b\">x</div>\n<!-- one\n two -->\n<span>end</span>\n"
        let ns = text as NSString
        let whole = tokenizer.tokens(in: text, range: NSRange(location: 0, length: ns.length))
        let chunked = chunkedTokens(tokenizer, text: text, chunkSize: 1)

        #expect(mergedTokens(chunked, kinds: [.tag]) == mergedTokens(whole, kinds: [.tag]))
        #expect(mergedTokens(chunked, kinds: [.comment]) == mergedTokens(whole, kinds: [.comment]))
    }

    @MainActor
    @Test func progressiveHighlighterCarriesMarkdownStateBetweenChunks() throws {
        let text = "intro\n```swift\n# not a heading\ncode\n```\nafter"
        let storage = NSTextStorage(string: text)
        let highlighter = try StorageHighlighter(rules: MarkdownFormat().highlightRules,
                                                 scanner: MarkdownScanner(),
                                                 theme: EditorTheme())
        var state = Tokenizer.State()
        applyLineChunks(with: highlighter, to: storage, state: &state)

        let ns = text as NSString
        let inside = ns.range(of: "# not a heading")
        #expect(sameColor(storage.attribute(.foregroundColor,
                                             at: inside.location,
                                             effectiveRange: nil) as? NSColor,
                           EditorTheme.light.color(for: .code)))
    }

    @MainActor
    @Test func progressiveHighlighterCarriesHTMLStateBetweenChunks() throws {
        let text = "<!-- one\n two -->\n<div\n title=\"a > b\">x</div>"
        let storage = NSTextStorage(string: text)
        let highlighter = try StorageHighlighter(rules: HTMLFormat().highlightRules,
                                                 scanner: HTMLScanner(),
                                                 theme: EditorTheme())
        var state = Tokenizer.State()
        applyLineChunks(with: highlighter, to: storage, state: &state)

        let ns = text as NSString
        #expect(sameColor(storage.attribute(.foregroundColor,
                                             at: ns.range(of: "two").location,
                                             effectiveRange: nil) as? NSColor,
                           EditorTheme.light.color(for: .comment)))
        #expect(sameColor(storage.attribute(.foregroundColor,
                                             at: ns.range(of: "<div").location,
                                             effectiveRange: nil) as? NSColor,
                           EditorTheme.light.color(for: .tag)))
        #expect(sameColor(storage.attribute(.foregroundColor,
                                             at: ns.range(of: "\"a > b\"").location,
                                             effectiveRange: nil) as? NSColor,
                           EditorTheme.light.color(for: .string)))
    }

    @MainActor
    @Test func localPassResumesFromTheNearestCheckpoint() throws {
        let text = String(repeating: "# Heading\nsome **bold** text\n```\ncode\n```\n",
                          count: 2_000)
        let storage = NSTextStorage(string: text)
        let highlighter = try StorageHighlighter(rules: MarkdownFormat().highlightRules,
                                                 scanner: MarkdownScanner(),
                                                 theme: EditorTheme())

        var state = Tokenizer.State()
        applyChunks(with: highlighter, to: storage, state: &state, maxLength: 50_000)
        #expect(highlighter.checkpointCount > 1)
        #expect(highlighter.checkpointOffsets.allSatisfy { $0 > 0 })

        let ns = storage.mutableString
        let dirty = ns.lineRange(for: NSRange(location: storage.length - 200, length: 1))
        highlighter.apply(to: storage, in: dirty)

        // Resuming from a checkpoint, not from document offset 0.
        #expect(highlighter.lastRecoveryStart > 0)
        #expect(highlighter.lastRecoveryStart <= dirty.location)
        #expect(dirty.location - highlighter.lastRecoveryStart <= 50_000 + 1)
    }

    @MainActor
    @Test func editsInvalidateCheckpointsAtAndAfterTheEdit() throws {
        let text = String(repeating: "# Heading\nsome **bold** text\n```\ncode\n```\n",
                          count: 2_000)
        let storage = NSTextStorage(string: text)
        let highlighter = try StorageHighlighter(rules: MarkdownFormat().highlightRules,
                                                 scanner: MarkdownScanner(),
                                                 theme: EditorTheme())
        var state = Tokenizer.State()
        applyChunks(with: highlighter, to: storage, state: &state, maxLength: 50_000)

        let cut = storage.length * 3 / 4
        highlighter.invalidateCheckpoints(from: cut)

        #expect(highlighter.checkpointOffsets.allSatisfy { $0 < cut })
        #expect(!highlighter.checkpointOffsets.isEmpty)
    }

    @MainActor
    @Test func checkpointedLocalPassColoursInsideAFence() throws {
        let text = String(repeating: "prose\n", count: 10_000)
            + "```\n"
            + String(repeating: "code line\n", count: 5_000)
            + "# not a heading\n"
            + "```\n"
        let storage = NSTextStorage(string: text)
        let highlighter = try StorageHighlighter(rules: MarkdownFormat().highlightRules,
                                                 scanner: MarkdownScanner(),
                                                 theme: EditorTheme())
        var state = Tokenizer.State()
        applyChunks(with: highlighter, to: storage, state: &state, maxLength: 50_000)

        let ns = storage.mutableString
        let inside = ns.range(of: "# not a heading")
        let line = ns.lineRange(for: inside)
        // Clear the full-pass result so this test proves the local pass alone.
        storage.setAttributes([:], range: line)

        highlighter.apply(to: storage, in: line)

        // The nearest checkpoint is inside the fence, so its open-fence state
        // (and the fence's original start) must have been carried across.
        #expect(highlighter.lastRecoveryStart > 0)
        #expect(sameColor(storage.attribute(.foregroundColor,
                                             at: inside.location,
                                             effectiveRange: nil) as? NSColor,
                           EditorTheme.light.color(for: .code)))
    }

    @MainActor
    private func applyChunks(with highlighter: StorageHighlighter,
                             to storage: NSTextStorage,
                             state: inout Tokenizer.State,
                             maxLength: Int) {
        var start = 0
        while start < storage.length {
            let ns = storage.mutableString
            let tentativeEnd = min(start + maxLength, storage.length)
            let line = ns.lineRange(for: NSRange(location: start,
                                                 length: tentativeEnd - start))
            let end = min(NSMaxRange(line), storage.length)
            highlighter.apply(to: storage,
                              in: NSRange(location: start, length: end - start),
                              state: &state)
            start = end
        }
    }

    @MainActor
    private func applyLineChunks(with highlighter: StorageHighlighter,
                                 to storage: NSTextStorage,
                                 state: inout Tokenizer.State) {
        let ns = storage.mutableString
        var start = 0
        while start < ns.length {
            let line = ns.lineRange(for: NSRange(location: start, length: 0))
            highlighter.apply(to: storage,
                              in: NSRange(location: start, length: NSMaxRange(line) - start),
                              state: &state)
            start = NSMaxRange(line)
        }
    }

    private func chunkedTokens(_ tokenizer: Tokenizer,
                               text: String,
                               chunkSize: Int) -> [Token] {
        let ns = text as NSString
        let lines = lineRanges(in: text)
        var state = Tokenizer.State()
        var result: [Token] = []
        var index = 0
        while index < lines.count {
            let endIndex = min(index + chunkSize, lines.count) - 1
            let start = lines[index].location
            let end = NSMaxRange(lines[endIndex])
            result.append(contentsOf: tokenizer.tokens(
                in: ns,
                range: NSRange(location: start, length: end - start),
                state: &state))
            index = endIndex + 1
        }
        return result
    }

    private func lineRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var result: [NSRange] = []
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            result.append(line)
            location = NSMaxRange(line)
        }
        return result
    }

    /// Joins adjacent tokens of the selected kinds. A construct split across
    /// chunks is emitted as one token per chunk; the merged result must match
    /// the single-pass token list.
    private func mergedTokens(_ tokens: [Token], kinds: Set<TokenKind>) -> [Token] {
        var result: [Token] = []
        for token in tokens where kinds.contains(token.kind) {
            if let last = result.last,
               last.kind == token.kind,
               NSMaxRange(last.range) == token.range.location {
                result[result.count - 1] = Token(range: NSUnionRange(last.range, token.range),
                                                 kind: token.kind)
            } else {
                result.append(token)
            }
        }
        return result
    }

    @Test func latexCommentsComeLastSoTheyWin() throws {
        let rules = LaTeXFormat().highlightRules
        #expect(rules.last?.kind == .comment)

        let tokenizer = try Tokenizer(rules: rules)
        let text = "\\alpha % note"
        let tokens = tokenizer.tokens(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        #expect(tokens.contains(Token(range: NSRange(location: 0, length: 6), kind: .command)))
        #expect(tokens.contains(Token(range: NSRange(location: 7, length: 6), kind: .comment)))
    }

    @MainActor
    @Test func highlighterOnlyTouchesWholeLinesInRange() throws {
        let highlighter = try StorageHighlighter(rules: MarkdownFormat().highlightRules,
                                                 theme: EditorTheme())
        let storage = NSTextStorage(string: "# Title\nplain")

        highlighter.apply(to: storage, in: NSRange(location: 0, length: 1))
        #expect(sameColor(storage.attribute(.foregroundColor,
                                             at: 0,
                                             effectiveRange: nil) as? NSColor,
                           EditorTheme.light.color(for: .heading)))
        #expect(storage.attribute(.foregroundColor, at: 9, effectiveRange: nil) == nil)

        highlighter.apply(to: storage, in: NSRange(location: 0, length: storage.length))
        #expect(sameColor(storage.attribute(.foregroundColor,
                                             at: 9,
                                             effectiveRange: nil) as? NSColor,
                           EditorTheme.light.text))
    }

    @MainActor
    @Test func zeroLengthRangeStillHighlightsItsLine() throws {
        let highlighter = try StorageHighlighter(rules: MarkdownFormat().highlightRules,
                                                 theme: EditorTheme())
        let storage = NSTextStorage(string: "plain\n# Title\nplain")

        // A pure deletion reports a zero-length dirty range; the line around
        // the deletion still needs to be coloured.
        highlighter.apply(to: storage, in: NSRange(location: 7, length: 0))

        #expect(sameColor(storage.attribute(.foregroundColor,
                                             at: 6,
                                             effectiveRange: nil) as? NSColor,
                           EditorTheme.light.color(for: .heading)))
    }

    @MainActor
    @Test func staleRangesAreClampedInsteadOfCrashing() throws {
        let highlighter = try StorageHighlighter(rules: MarkdownFormat().highlightRules,
                                                 theme: EditorTheme())
        let storage = NSTextStorage(string: "short")
        highlighter.apply(to: storage, in: NSRange(location: 500, length: 500))
        highlighter.apply(to: NSTextStorage(string: ""), in: NSRange(location: 3, length: 3))
    }

    /// Resolve adaptive colours under a fixed light appearance so a test run in
    /// a dark system appearance compares against the same palette.
    private func sameColor(_ actual: NSColor?, _ expected: NSColor) -> Bool {
        guard let actual else { return false }
        let appearance = NSAppearance(named: .aqua)!
        var actualComponents: [CGFloat] = []
        var expectedComponents: [CGFloat] = []
        appearance.performAsCurrentDrawingAppearance {
            actualComponents = components(actual)
            expectedComponents = components(expected)
        }
        return zip(actualComponents, expectedComponents).allSatisfy { abs($0 - $1) < 0.001 }
    }

    private func components(_ color: NSColor) -> [CGFloat] {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
    }
}
