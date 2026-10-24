import Testing
import AppKit
import UniformTypeIdentifiers
@testable import ModEditCore

@Suite("FormatRegistry")
struct FormatRegistryTests {
    let registry = FormatRegistry.standard

    @Test func exactMatchesPickTheirOwnFormat() {
        #expect(registry.format(for: .markdownText).id == "markdown")
        #expect(registry.format(for: .latex).id == "latex")
        #expect(registry.format(for: .html).id == "html")
        #expect(registry.format(for: .plainText).id == "plaintext")
    }

    @Test func unknownTypesFallBackToPlainText() {
        #expect(registry.format(for: .json).id == "plaintext")
    }

    @Test func idsAreUnique() {
        let ids = registry.allFormats.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func lookupByID() {
        #expect(registry.format(withID: "latex")?.displayName == "LaTeX")
        #expect(registry.format(withID: "nope") == nil)
    }
}

@Suite("Highlighting")
struct HighlightingTests {

    @Test func everyShippedRuleCompiles() throws {
        for format in FormatRegistry.standard.allFormats {
            _ = try Tokenizer(rules: format.highlightRules)
        }
    }

    @Test func invalidPatternThrows() {
        #expect(throws: (any Error).self) {
            _ = try Tokenizer(rules: [HighlightRule("(", .code)])
        }
    }

    @Test func markdownTokens() throws {
        let tokenizer = try Tokenizer(rules: MarkdownFormat().highlightRules)
        let text = "# Title\n`code`"
        let tokens = tokenizer.tokens(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        #expect(tokens.contains(Token(range: NSRange(location: 0, length: 7), kind: .heading)))
        #expect(tokens.contains(Token(range: NSRange(location: 8, length: 6), kind: .code)))
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
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemBlue)
        #expect(storage.attribute(.foregroundColor, at: 9, effectiveRange: nil) == nil)

        highlighter.apply(to: storage, in: NSRange(location: 0, length: storage.length))
        #expect(storage.attribute(.foregroundColor, at: 9, effectiveRange: nil) as? NSColor == .textColor)
    }

    @MainActor
    @Test func staleRangesAreClampedInsteadOfCrashing() throws {
        let highlighter = try StorageHighlighter(rules: MarkdownFormat().highlightRules,
                                                 theme: EditorTheme())
        let storage = NSTextStorage(string: "short")
        highlighter.apply(to: storage, in: NSRange(location: 500, length: 500))
        highlighter.apply(to: NSTextStorage(string: ""), in: NSRange(location: 3, length: 3))
    }
}
