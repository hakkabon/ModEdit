import Foundation

/// What a piece of text *is*, independent of how it is drawn.
///
/// Formats classify text into kinds; `EditorTheme` decides fonts and colours.
/// Keeping the two apart makes rules testable without AppKit and makes
/// re-theming trivial.
enum TokenKind: Sendable, Hashable, CaseIterable {
    case comment
    case tag
    case attributeName
    case string
    case command
    case math
    case argument
    case optionalArgument
    case heading
    case strong
    case code
    case link
    case quote
    case listMarker
}

/// A regular expression that classifies the text it matches.
///
/// Holds only a pattern string so it is `Sendable`; compilation happens in
/// `Tokenizer`, which reports invalid patterns by throwing (and the test suite
/// compiles every shipped rule, so a typo cannot silently disable highlighting).
struct HighlightRule: Sendable {
    let pattern: String
    let kind: TokenKind

    init(_ pattern: String, _ kind: TokenKind) {
        self.pattern = pattern
        self.kind = kind
    }
}

/// A classified range. Ranges are UTF-16 offsets (`NSRange`).
struct Token: Equatable, Sendable {
    let range: NSRange
    let kind: TokenKind
}

/// Finds tokens by running a format's rules over (part of) a string.
///
/// Tokens are returned **in rule order**. Applying them in that order, later
/// rules overwrite earlier ones, which is the priority scheme documented on
/// `DocumentFormat.highlightRules`.
///
/// This is deliberately a line-oriented regular-expression tokenizer: simple
/// and fast, but it cannot see constructs that span lines (fenced code blocks,
/// multi-line HTML comments). Replacing it with a stateful lexer is on the
/// roadmap; the `HighlightRule` -> `TokenKind` boundary is designed so that
/// swap does not touch the formats' public shape.
struct Tokenizer {
    private struct CompiledRule {
        let regex: NSRegularExpression
        let kind: TokenKind
    }

    private let rules: [CompiledRule]

    /// - Throws: if any rule's pattern is not a valid regular expression.
    init(rules: [HighlightRule]) throws {
        self.rules = try rules.map {
            CompiledRule(
                regex: try NSRegularExpression(pattern: $0.pattern, options: [.anchorsMatchLines]),
                kind: $0.kind)
        }
    }

    /// Tokens whose matches lie within `range` of `text`.
    ///
    /// `range` should start and end on line boundaries so `^` and `$` behave.
    func tokens(in text: String, range: NSRange) -> [Token] {
        var result: [Token] = []
        for rule in rules {
            rule.regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match, match.range.length > 0 else { return }
                result.append(Token(range: match.range, kind: rule.kind))
            }
        }
        return result
    }
}
