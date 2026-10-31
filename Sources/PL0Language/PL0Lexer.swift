import Foundation

public struct LexResult: Sendable {
    public let tokens: [PL0Token]
    public let losslessTokens: [PL0LosslessToken]
    public let diagnostics: [ParseDiagnostic]

    public init(tokens: [PL0Token], losslessTokens: [PL0LosslessToken] = [],
                diagnostics: [ParseDiagnostic]) {
        self.tokens = tokens
        self.losslessTokens = losslessTokens
        self.diagnostics = diagnostics
    }
}

struct ScannerOutput {
    var tokens: [PL0Token]
    var losslessTokens: [PL0LosslessToken]
    var diagnostics: [ParseDiagnostic]
    var scannedEnd: Int
    var stoppedForConvergence: Bool
}

/// Reference PL/0 scanner using UTF-16 offsets throughout, so ranges can be
/// passed directly to TextKit and LSP without lossy conversions.
public struct PL0Lexer: Sendable {
    public let languageKit: PL0LanguageKit

    public init(languageKit: PL0LanguageKit = .bundled) {
        self.languageKit = languageKit
    }

    public func tokenize(_ snapshot: SourceSnapshot) -> LexResult {
        let output = scan(snapshot.text as NSString,
                          from: SourceLocation(offset: 0, line: 1, column: 1),
                          version: snapshot.version)
        return LexResult(tokens: output.tokens, losslessTokens: output.losslessTokens,
                         diagnostics: output.diagnostics)
    }

    /// Scans from a known-normal token boundary. The convergence predicate is
    /// called before a token is appended, allowing the caller to reuse the old
    /// suffix including the matching token.
    func scan(_ text: NSString,
              from initial: SourceLocation,
              version: UInt64,
              shouldConverge: ((PL0Token) -> Bool)? = nil) -> ScannerOutput {
        var tokens: [PL0Token] = []
        var losslessTokens: [PL0LosslessToken] = []
        var diagnostics: [ParseDiagnostic] = []
        var offset = initial.offset
        var line = initial.line
        var column = initial.column
        var ordinal = 0
        var triviaOrdinal = 0

        func isLetter(_ value: unichar) -> Bool {
            (65...90).contains(value) || (97...122).contains(value) || value == 95
        }
        func isASCIIDigit(_ value: unichar) -> Bool { (48...57).contains(value) }
        func isIdentifierContinuation(_ value: unichar) -> Bool {
            isLetter(value) || isASCIIDigit(value)
        }
        func isWhitespace(_ value: unichar) -> Bool {
            guard let scalar = UnicodeScalar(value) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        func makeToken(_ kind: PL0TokenKind, from start: Int,
                       line: Int, column: Int) -> PL0Token {
            let range = NSRange(location: start, length: offset - start)
            defer { ordinal += 1 }
            return PL0Token(id: "v\(version):\(start):\(ordinal)", kind: kind,
                            lexeme: text.substring(with: range),
                            range: SourceRange(location: range.location, length: range.length),
                            location: SourceLocation(offset: start, line: line, column: column))
        }
        func appendTrivia(_ kind: PL0TriviaKind, from start: Int,
                          line: Int, column: Int) {
            let range = SourceRange(location: start, length: offset - start)
            let value = text.substring(with: NSRange(location: start,
                                                      length: offset - start))
            losslessTokens.append(PL0LosslessToken(
                id: "v\(version):trivia:\(start):\(triviaOrdinal)",
                kind: .trivia(kind), lexeme: value, range: range,
                location: SourceLocation(offset: start, line: line, column: column)))
            triviaOrdinal += 1
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
        func emit(_ token: PL0Token) -> Bool {
            if shouldConverge?(token) == true { return true }
            tokens.append(token)
            if token.kind != .endOfFile {
                losslessTokens.append(PL0LosslessToken(
                    id: token.id, kind: .token(token.kind), lexeme: token.lexeme,
                    range: token.range, location: token.location))
            }
            if token.kind == .invalid {
                diagnostics.append(ParseDiagnostic(
                    severity: .error, message: "Unexpected character '\(token.lexeme)'",
                    range: token.range))
            }
            return false
        }
        func stopped(at token: PL0Token) -> ScannerOutput {
            ScannerOutput(tokens: tokens, losslessTokens: losslessTokens,
                          diagnostics: diagnostics,
                          scannedEnd: token.range.location,
                          stoppedForConvergence: true)
        }

        while offset < text.length {
            let character = text.character(at: offset)
            if isWhitespace(character) {
                let start = offset, startLine = line, startColumn = column
                advance()
                while offset < text.length
                        && isWhitespace(text.character(at: offset)) {
                    advance()
                }
                appendTrivia(.whitespace, from: start, line: startLine, column: startColumn)
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
                let token = makeToken(languageKit.keywordKind(spelling) ?? .identifier,
                                      from: start, line: startLine, column: startColumn)
                if emit(token) { return stopped(at: token) }
                continue
            }
            if isASCIIDigit(character) {
                advance()
                while offset < text.length {
                    guard isASCIIDigit(text.character(at: offset)) else { break }
                    advance()
                }
                let token = makeToken(.number, from: start,
                                      line: startLine, column: startColumn)
                if emit(token) { return stopped(at: token) }
                continue
            }

            // C-style comments are a deliberate PL/0 workbench extension.
            if character == 47, offset + 1 < text.length,
               text.character(at: offset + 1) == 47 {
                while offset < text.length
                        && text.character(at: offset) != 10
                        && text.character(at: offset) != 13 { advance() }
                appendTrivia(.lineComment, from: start,
                             line: startLine, column: startColumn)
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
                appendTrivia(.blockComment, from: start,
                             line: startLine, column: startColumn)
                continue
            }

            let scalarLength = (0xD800...0xDBFF).contains(character)
                && offset + 1 < text.length
                && (0xDC00...0xDFFF).contains(text.character(at: offset + 1)) ? 2 : 1
            var spelling = text.substring(with: NSRange(location: offset,
                                                         length: scalarLength))
            if offset + 1 < text.length {
                let pair = text.substring(with: NSRange(location: offset, length: 2))
                if languageKit.operatorKind(pair) != nil { spelling = pair }
            }
            for _ in spelling.utf16 { advance() }
            let kind = languageKit.operatorKind(spelling) ?? .invalid
            let token = makeToken(kind, from: start, line: startLine, column: startColumn)
            if emit(token) { return stopped(at: token) }
        }

        let eof = PL0Token(id: "v\(version):\(offset):eof", kind: .endOfFile, lexeme: "",
            range: SourceRange(location: offset, length: 0),
            location: SourceLocation(offset: offset, line: line, column: column))
        if emit(eof) { return stopped(at: eof) }
        return ScannerOutput(tokens: tokens, losslessTokens: losslessTokens,
                             diagnostics: diagnostics,
                             scannedEnd: offset, stoppedForConvergence: false)
    }
}
