import Foundation
import Testing
@testable import PL0Language

@Suite("PL/0 incremental tokenizer")
struct IncrementalTokenizerTests {
    @Test func localEditReusesBothSidesAndScansOnlyToConvergence() throws {
        let original = "const limit = 10; var x; begin x := limit end."
        var tokenizer = PL0IncrementalTokenizer()
        let first = tokenizer.tokenize(SourceSnapshot(version: 1, text: original))
        let range = (original as NSString).range(of: "10")
        let changed = (original as NSString).replacingCharacters(in: range, with: "100")
        let second = tokenizer.tokenize(SourceSnapshot(
            version: 2, text: changed,
            edit: SourceEdit(baseVersion: 1,
                             replacedRange: sourceRange(range), replacementLength: 3)))

        expectEquivalent(second.lexed, toFullLexOf: changed, version: 2)
        #expect(!first.metrics.incremental)
        #expect(second.metrics.incremental)
        #expect(second.metrics.converged)
        #expect(second.metrics.reusedPrefixTokenCount > 0)
        #expect(second.metrics.reusedSuffixTokenCount > 0)
        #expect(second.metrics.scannedUTF16Length < changed.utf16.count)
    }

    @Test func reusedSuffixKeepsIdentityWhenItsOffsetMoves() throws {
        let original = "var x; begin x := 1 end."
        var tokenizer = PL0IncrementalTokenizer()
        let first = tokenizer.tokenize(SourceSnapshot(version: 10, text: original))
        let insertion = (original as NSString).range(of: "begin").location
        let changed = (original as NSString).replacingCharacters(
            in: NSRange(location: insertion, length: 0), with: "\n\n")
        let second = tokenizer.tokenize(SourceSnapshot(
            version: 11, text: changed,
            edit: SourceEdit(baseVersion: 10,
                             replacedRange: SourceRange(location: insertion, length: 0),
                             replacementLength: 2)))

        expectEquivalent(second.lexed, toFullLexOf: changed, version: 11)
        let oldEnd = try #require(first.lexed.tokens.first { $0.kind == .end })
        let newEnd = try #require(second.lexed.tokens.first { $0.kind == .end })
        #expect(newEnd.id == oldEnd.id)
        #expect(newEnd.range.location == oldEnd.range.location + 2)
        #expect(newEnd.location.line == oldEnd.location.line + 2)
    }

    @Test func editAtTokenBoundaryRescansTokenThatCanMerge() throws {
        let original = "var x; begin x := 1 end."
        var tokenizer = PL0IncrementalTokenizer()
        let first = tokenizer.tokenize(SourceSnapshot(version: 1, text: original))
        let identifier = try #require(first.lexed.tokens.first { $0.lexeme == "x" })
        let changed = (original as NSString).replacingCharacters(
            in: NSRange(location: identifier.range.end, length: 0), with: "y")
        let second = tokenizer.tokenize(SourceSnapshot(
            version: 2, text: changed,
            edit: SourceEdit(baseVersion: 1,
                             replacedRange: SourceRange(location: identifier.range.end, length: 0),
                             replacementLength: 1)))

        expectEquivalent(second.lexed, toFullLexOf: changed, version: 2)
        #expect(second.lexed.tokens.contains { $0.lexeme == "xy" })
        #expect(!second.lexed.tokens.contains { $0.id == identifier.id })
    }

    @Test func unterminatedCommentOnlyConvergesAtEndOfFile() {
        let original = "var x; /* note */ begin x := 1 end."
        var tokenizer = PL0IncrementalTokenizer()
        _ = tokenizer.tokenize(SourceSnapshot(version: 1, text: original))
        let closingSlash = (original as NSString).range(of: "*/").location + 1
        let changed = (original as NSString).replacingCharacters(
            in: NSRange(location: closingSlash, length: 1), with: "")
        let result = tokenizer.tokenize(SourceSnapshot(
            version: 2, text: changed,
            edit: SourceEdit(baseVersion: 1,
                             replacedRange: SourceRange(location: closingSlash, length: 1),
                             replacementLength: 0)))

        expectEquivalent(result.lexed, toFullLexOf: changed, version: 2)
        // EOF is safe to reuse after scanning the complete changed suffix; no
        // source token following the now-unterminated comment is reused.
        #expect(result.metrics.converged)
        #expect(result.metrics.reusedSuffixTokenCount == 1)
        #expect(result.lexed.tokens.suffix(1).first?.kind == .endOfFile)
        #expect(result.lexed.diagnostics.contains { $0.message == "Unterminated block comment" })
    }

    @Test func skippedBaseVersionFallsBackInsteadOfUsingTheWrongEdit() {
        let original = "var x; begin x := 1 end."
        var tokenizer = PL0IncrementalTokenizer()
        _ = tokenizer.tokenize(SourceSnapshot(version: 1, text: original))
        let changed = "var y; begin y := 2 end."
        let result = tokenizer.tokenize(SourceSnapshot(
            version: 3, text: changed,
            edit: SourceEdit(baseVersion: 2,
                             replacedRange: SourceRange(location: 4, length: 1),
                             replacementLength: 1)))

        expectEquivalent(result.lexed, toFullLexOf: changed, version: 3)
        #expect(!result.metrics.incremental)
        #expect(result.metrics.scannedUTF16Length == changed.utf16.count)
    }

    @Test func editSequenceAlwaysMatchesFullTokenization() {
        var text = "const n = 10;\nvar x;\nbegin\n  x := n\nend."
        var version: UInt64 = 1
        var tokenizer = PL0IncrementalTokenizer()
        _ = tokenizer.tokenize(SourceSnapshot(version: version, text: text))

        let edits: [(String, String)] = [
            ("10", "100"),
            ("var x;", "var x, y;"),
            ("begin", "begin\n  // initialize"),
            ("x := n", "x := (n + 1) * 2"),
            ("end.", "if odd x then y := x;\nend."),
            ("// initialize", "/* initialize */"),
        ]

        for (needle, replacement) in edits {
            let range = (text as NSString).range(of: needle)
            #expect(range.location != NSNotFound)
            let next = (text as NSString).replacingCharacters(in: range, with: replacement)
            let oldVersion = version
            version += 1
            let result = tokenizer.tokenize(SourceSnapshot(
                version: version, text: next,
                edit: SourceEdit(baseVersion: oldVersion,
                                 replacedRange: sourceRange(range),
                                 replacementLength: (replacement as NSString).length)))
            expectEquivalent(result.lexed, toFullLexOf: next, version: version)
            text = next
        }
    }

    @Test func randomizedMutationsAlwaysMatchFullTokenization() {
        var text = "const n = 10;\nvar x;\n/* note */ begin x := n end."
        var version: UInt64 = 1
        var tokenizer = PL0IncrementalTokenizer()
        _ = tokenizer.tokenize(SourceSnapshot(version: version, text: text))
        var random = LCG(state: 0x5EED_CAFE)
        let replacements = ["", "x", "12", " ", "\n", ";", ":=", "/*", "*/", "//"]

        for _ in 0..<200 {
            let length = (text as NSString).length
            let location = random.nextInt(upperBound: length + 1)
            let maximumDeletion = min(3, length - location)
            let deletion = random.nextInt(upperBound: maximumDeletion + 1)
            let replacement = replacements[random.nextInt(upperBound: replacements.count)]
            let range = NSRange(location: location, length: deletion)
            let next = (text as NSString).replacingCharacters(in: range, with: replacement)
            let oldVersion = version
            version += 1
            let result = tokenizer.tokenize(SourceSnapshot(
                version: version, text: next,
                edit: SourceEdit(baseVersion: oldVersion,
                                 replacedRange: sourceRange(range),
                                 replacementLength: (replacement as NSString).length)))

            expectEquivalent(result.lexed, toFullLexOf: next, version: version)
            #expect(Set(result.lexed.tokens.map(\.id)).count == result.lexed.tokens.count)
            #expect(Set(result.lexed.losslessTokens.map(\.id)).count
                    == result.lexed.losslessTokens.count)
            #expect(result.lexed.losslessTokens.map(\.lexeme).joined() == next)
            text = next
        }
    }

    private func expectEquivalent(_ actual: LexResult, toFullLexOf text: String,
                                  version: UInt64) {
        let expected = PL0Lexer().tokenize(SourceSnapshot(version: version, text: text))
        #expect(actual.tokens.map(TokenView.init) == expected.tokens.map(TokenView.init))
        #expect(actual.losslessTokens.map(LosslessTokenView.init)
                == expected.losslessTokens.map(LosslessTokenView.init))
        #expect(actual.losslessTokens.map(\.lexeme).joined() == text)
        #expect(actual.diagnostics.map(DiagnosticView.init)
                == expected.diagnostics.map(DiagnosticView.init))
    }

    private func sourceRange(_ range: NSRange) -> SourceRange {
        SourceRange(location: range.location, length: range.length)
    }

    private struct TokenView: Equatable {
        let kind: PL0TokenKind
        let lexeme: String
        let range: SourceRange
        let location: PL0Language.SourceLocation

        init(_ token: PL0Token) {
            kind = token.kind
            lexeme = token.lexeme
            range = token.range
            location = token.location
        }
    }

    private struct DiagnosticView: Equatable {
        let severity: DiagnosticSeverity
        let message: String
        let range: SourceRange

        init(_ diagnostic: ParseDiagnostic) {
            severity = diagnostic.severity
            message = diagnostic.message
            range = diagnostic.range
        }
    }

    private struct LosslessTokenView: Equatable {
        let kind: PL0LosslessTokenKind
        let lexeme: String
        let range: SourceRange
        let location: PL0Language.SourceLocation

        init(_ token: PL0LosslessToken) {
            kind = token.kind
            lexeme = token.lexeme
            range = token.range
            location = token.location
        }
    }

    private struct LCG {
        var state: UInt64

        mutating func nextInt(upperBound: Int) -> Int {
            precondition(upperBound > 0)
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int(state % UInt64(upperBound))
        }
    }
}
