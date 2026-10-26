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

/// Selects the state machine used around a format's regex rules.
enum HighlightingMode: Sendable {
    case regularExpressions
    case markdown
    case html
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
/// Local syntax uses ordered regular expressions. Formats can additionally
/// select a small state machine for constructs that cross line boundaries,
/// currently Markdown fences and HTML tags/comments.
struct Tokenizer {
    private struct CompiledRule {
        let regex: NSRegularExpression
        let kind: TokenKind
    }

    private let rules: [CompiledRule]
    private let mode: HighlightingMode

    /// - Throws: if any rule's pattern is not a valid regular expression.
    init(rules: [HighlightRule], mode: HighlightingMode = .regularExpressions) throws {
        self.mode = mode
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
        let ns = text as NSString
        let documentRange = NSRange(location: 0, length: ns.length)
        let requested = NSIntersectionRange(range, documentRange)
        guard requested.location != NSNotFound else { return [] }

        let htmlTokens = mode == .html ? scanHTML(in: ns, clippedTo: requested) : (tags: [], comments: [])
        var result: [Token] = htmlTokens.tags
        for rule in rules {
            rule.regex.enumerateMatches(in: text, options: [], range: requested) { match, _, _ in
                guard let match, match.range.length > 0 else { return }
                if mode == .html,
                   !htmlTokens.tags.contains(where: { NSLocationInRange(match.range.location, $0.range) }) {
                    return
                }
                result.append(Token(range: match.range, kind: rule.kind))
            }
        }
        if mode == .markdown {
            // Fenced blocks are opaque, so append them after inline rules.
            result.append(contentsOf: markdownFenceTokens(in: ns, clippedTo: requested))
        } else if mode == .html {
            // Comments are opaque and must override tag/attribute/string tokens.
            result.append(contentsOf: htmlTokens.comments)
        }
        return result
    }

    private func clippedToken(_ range: NSRange, kind: TokenKind, to requested: NSRange) -> Token? {
        let clipped = NSIntersectionRange(range, requested)
        guard clipped.location != NSNotFound, clipped.length > 0 else { return nil }
        return Token(range: clipped, kind: kind)
    }

    /// Scans from the beginning so a requested range starting inside a fence
    /// still has the correct state. Tokens are clipped to the requested lines.
    private func markdownFenceTokens(in text: NSString, clippedTo requested: NSRange) -> [Token] {
        var result: [Token] = []
        var offset = 0
        var fenceStart: Int?
        let scanLimit = NSMaxRange(requested)
        while offset < scanLimit {
            let line = text.lineRange(for: NSRange(location: offset, length: 0))
            let value = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("```") {
                if let start = fenceStart {
                    if let token = clippedToken(NSRange(location: start, length: NSMaxRange(line) - start),
                                                kind: .code, to: requested) { result.append(token) }
                    fenceStart = nil
                } else {
                    fenceStart = line.location
                }
            }
            offset = NSMaxRange(line)
        }
        if let start = fenceStart,
           let token = clippedToken(NSRange(location: start, length: text.length - start),
                                    kind: .code, to: requested) { result.append(token) }
        return result
    }

    /// A small HTML state machine. Unlike `<[^>]+>`, it handles newlines and
    /// `>` characters inside quoted attribute values.
    private func scanHTML(in text: NSString, clippedTo requested: NSRange) -> (tags: [Token], comments: [Token]) {
        var tags: [Token] = []
        var comments: [Token] = []
        var index = 0
        let scanLimit = NSMaxRange(requested)
        while index < scanLimit {
            if hasPrefix("<!--", at: index, in: text) {
                let start = index
                index += 4
                while index < scanLimit, !hasPrefix("-->", at: index, in: text) { index += 1 }
                index = min(index + (index < scanLimit ? 3 : 0), scanLimit)
                if let token = clippedToken(NSRange(location: start, length: index - start),
                                            kind: .comment, to: requested) { comments.append(token) }
                continue
            }
            guard text.character(at: index) == 0x3C else { index += 1; continue } // <
            let start = index
            index += 1
            var quote: unichar?
            while index < scanLimit {
                let character = text.character(at: index)
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else if character == 0x22 || character == 0x27 { // " or '
                    quote = character
                } else if character == 0x3E { // >
                    index += 1
                    break
                }
                index += 1
            }
            if let token = clippedToken(NSRange(location: start, length: index - start),
                                        kind: .tag, to: requested) { tags.append(token) }
        }
        return (tags, comments)
    }

    private func hasPrefix(_ prefix: String, at location: Int, in text: NSString) -> Bool {
        let length = (prefix as NSString).length
        guard location + length <= text.length else { return false }
        return text.substring(with: NSRange(location: location, length: length)) == prefix
    }
}
