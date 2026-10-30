import Foundation

public struct LexResult: Sendable {
    public let tokens: [PL0Token]
    public let diagnostics: [ParseDiagnostic]
}

/// Reference PL/0 scanner using UTF-16 offsets throughout, so ranges can be
/// passed directly to TextKit and LSP without lossy conversions.
public struct PL0Lexer: Sendable {
    private static let keywords: [String: PL0TokenKind] = [
        "const": .const, "var": .varKeyword, "procedure": .procedure,
        "call": .call, "begin": .begin, "end": .end, "if": .ifKeyword,
        "then": .then, "while": .whileKeyword, "do": .doKeyword, "odd": .odd,
    ]

    public init() {}

    public func tokenize(_ snapshot: SourceSnapshot) -> LexResult {
        let text = snapshot.text as NSString
        var tokens: [PL0Token] = []
        var diagnostics: [ParseDiagnostic] = []
        var offset = 0
        var line = 1
        var column = 1

        func isLetter(_ value: unichar) -> Bool {
            (65...90).contains(value) || (97...122).contains(value) || value == 95
        }
        func isASCIIDigit(_ value: unichar) -> Bool { (48...57).contains(value) }
        func isIdentifierContinuation(_ value: unichar) -> Bool {
            isLetter(value) || isASCIIDigit(value)
        }
        func makeToken(_ kind: PL0TokenKind, from start: Int,
                       line: Int, column: Int) -> PL0Token {
            let range = NSRange(location: start, length: offset - start)
            return PL0Token(kind: kind, lexeme: text.substring(with: range),
                            range: SourceRange(location: range.location, length: range.length),
                            location: SourceLocation(offset: start, line: line, column: column))
        }
        func advance() {
            guard offset < text.length else { return }
            let character = text.character(at: offset)
            if character == 13 {
                offset += (offset + 1 < text.length && text.character(at: offset + 1) == 10) ? 2 : 1
                line += 1
                column = 1
            } else if character == 10 {
                offset += 1
                line += 1
                column = 1
            } else {
                offset += 1
                column += 1
            }
        }

        while offset < text.length {
            let character = text.character(at: offset)
            if CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(character)!) {
                advance()
                continue
            }

            let start = offset
            let startLine = line
            let startColumn = column
            if isLetter(character) {
                advance()
                while offset < text.length {
                    guard isIdentifierContinuation(text.character(at: offset)) else { break }
                    advance()
                }
                let spelling = text.substring(with: NSRange(location: start, length: offset - start))
                tokens.append(makeToken(Self.keywords[spelling.lowercased()] ?? .identifier,
                                        from: start, line: startLine, column: startColumn))
                continue
            }
            if isASCIIDigit(character) {
                advance()
                while offset < text.length {
                    guard isASCIIDigit(text.character(at: offset)) else { break }
                    advance()
                }
                tokens.append(makeToken(.number, from: start,
                                        line: startLine, column: startColumn))
                continue
            }

            // C-style comments are a deliberate PL/0 workbench extension.
            if character == 47, offset + 1 < text.length,
               text.character(at: offset + 1) == 47 {
                while offset < text.length
                        && text.character(at: offset) != 10
                        && text.character(at: offset) != 13 { advance() }
                continue
            }
            if character == 47, offset + 1 < text.length,
               text.character(at: offset + 1) == 42 {
                advance(); advance()
                while offset < text.length
                        && !(text.character(at: offset) == 42
                            && offset + 1 < text.length
                            && text.character(at: offset + 1) == 47) { advance() }
                if offset < text.length { advance(); advance() }
                else {
                    diagnostics.append(ParseDiagnostic(
                        severity: .error, message: "Unterminated block comment",
                        range: SourceRange(location: start, length: offset - start)))
                }
                continue
            }

            let kind: PL0TokenKind
            switch character {
            case 43: kind = .plus
            case 45: kind = .minus
            case 42: kind = .star
            case 47: kind = .slash
            case 61: kind = .equal
            case 35: kind = .notEqual
            case 44: kind = .comma
            case 59: kind = .semicolon
            case 46: kind = .period
            case 40: kind = .leftParen
            case 41: kind = .rightParen
            case 58 where offset + 1 < text.length && text.character(at: offset + 1) == 61:
                advance(); kind = .assign
            case 60 where offset + 1 < text.length && text.character(at: offset + 1) == 61:
                advance(); kind = .lessEqual
            case 62 where offset + 1 < text.length && text.character(at: offset + 1) == 61:
                advance(); kind = .greaterEqual
            case 60: kind = .less
            case 62: kind = .greater
            default: kind = .invalid
            }
            advance()
            let token = makeToken(kind, from: start, line: startLine, column: startColumn)
            tokens.append(token)
            if kind == .invalid {
                diagnostics.append(ParseDiagnostic(
                    severity: .error, message: "Unexpected character '\(token.lexeme)'",
                    range: token.range))
            }
        }

        tokens.append(PL0Token(kind: .endOfFile, lexeme: "",
            range: SourceRange(location: offset, length: 0),
            location: SourceLocation(offset: offset, line: line, column: column)))
        return LexResult(tokens: tokens, diagnostics: diagnostics)
    }
}
