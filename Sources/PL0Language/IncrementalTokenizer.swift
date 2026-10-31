import Foundation

public struct IncrementalLexMetrics: Sendable, Equatable {
    public let scannedUTF16Length: Int
    public let generatedTokenCount: Int
    public let reusedPrefixTokenCount: Int
    public let reusedSuffixTokenCount: Int
    public let converged: Bool
    public let incremental: Bool

    public init(scannedUTF16Length: Int, generatedTokenCount: Int,
                reusedPrefixTokenCount: Int, reusedSuffixTokenCount: Int,
                converged: Bool, incremental: Bool) {
        self.scannedUTF16Length = scannedUTF16Length
        self.generatedTokenCount = generatedTokenCount
        self.reusedPrefixTokenCount = reusedPrefixTokenCount
        self.reusedSuffixTokenCount = reusedSuffixTokenCount
        self.converged = converged
        self.incremental = incremental
    }
}

public struct IncrementalLexResult: Sendable {
    public let version: UInt64
    public let lexed: LexResult
    public let metrics: IncrementalLexMetrics
}

/// Stateful incremental tokenizer for one document.
///
/// It preserves tokens strictly before a safe restart boundary, scans from
/// there, and stops as soon as a token aligns with the unchanged old suffix.
/// Remaining tokens keep their identities and receive relocated ranges/source
/// locations. A missing or inconsistent edit falls back to a full scan.
public struct PL0IncrementalTokenizer: Sendable {
    private struct State: Sendable {
        let version: UInt64
        let text: String
        let lexed: LexResult
    }

    private var previous: State?
    private let languageKit: PL0LanguageKit

    public init(languageKit: PL0LanguageKit = .bundled) {
        self.languageKit = languageKit
    }

    public mutating func tokenize(_ snapshot: SourceSnapshot) -> IncrementalLexResult {
        guard let old = previous,
              let edit = snapshot.edit,
              snapshot.version > old.version,
              edit.baseVersion == nil || edit.baseVersion == old.version,
              isConsistent(edit: edit, oldText: old.text, newText: snapshot.text) else {
            return fullTokenize(snapshot)
        }

        let oldTokens = old.lexed.tokens
        let prefixCount = oldTokens.prefix { token in
            token.kind != .endOfFile && token.range.end < edit.replacedRange.location
        }.count
        let prefix = Array(oldTokens.prefix(prefixCount))
        let restart = prefix.last.map { token in
            SourceLocation(offset: token.range.end,
                           line: token.location.line,
                           column: token.location.column + token.range.length)
        } ?? SourceLocation(offset: 0, line: 1, column: 1)

        let delta = edit.replacementLength - edit.replacedRange.length
        let newEditEnd = edit.replacedRange.location + edit.replacementLength
        let oldIndexByLocation = Dictionary(uniqueKeysWithValues:
            oldTokens.enumerated().map { ($0.element.range.location, $0.offset) })
        var convergedOldIndex: Int?
        var convergencePair: (new: PL0Token, old: PL0Token)?

        let scanned = PL0Lexer(languageKit: languageKit).scan(snapshot.text as NSString,
                                      from: restart,
                                      version: snapshot.version) { newToken in
            guard newToken.range.location >= newEditEnd else { return false }
            let oldLocation = newToken.range.location - delta
            guard let oldIndex = oldIndexByLocation[oldLocation],
                  oldIndex >= prefixCount else { return false }
            let oldToken = oldTokens[oldIndex]
            guard oldToken.kind == newToken.kind,
                  oldToken.lexeme == newToken.lexeme else { return false }
            convergedOldIndex = oldIndex
            convergencePair = (newToken, oldToken)
            return true
        }

        var tokens = prefix + scanned.tokens
        let losslessPrefix = old.lexed.losslessTokens.filter { $0.range.end <= restart.offset }
        var losslessTokens = losslessPrefix + scanned.losslessTokens
        var suffix: [PL0Token] = []
        if let oldIndex = convergedOldIndex, let pair = convergencePair {
            suffix = oldTokens[oldIndex...].map {
                relocate($0, delta: delta, oldAnchor: pair.old, newAnchor: pair.new)
            }
            tokens.append(contentsOf: suffix)
            if let losslessIndex = old.lexed.losslessTokens.firstIndex(where: {
                $0.id == pair.old.id
            }) {
                losslessTokens.append(contentsOf: old.lexed.losslessTokens[losslessIndex...].map {
                    relocate($0, delta: delta, oldAnchor: pair.old, newAnchor: pair.new)
                })
            }
        }

        let prefixDiagnostics = old.lexed.diagnostics.filter {
            $0.range.end <= restart.offset
        }
        var diagnostics = prefixDiagnostics + scanned.diagnostics
        if let pair = convergencePair {
            diagnostics.append(contentsOf: old.lexed.diagnostics
                .filter { $0.range.location >= pair.old.range.location }
                .map { relocate($0, delta: delta) })
        }

        let result = LexResult(tokens: tokens, losslessTokens: losslessTokens,
                               diagnostics: diagnostics)
        previous = State(version: snapshot.version, text: snapshot.text, lexed: result)
        return IncrementalLexResult(
            version: snapshot.version,
            lexed: result,
            metrics: IncrementalLexMetrics(
                scannedUTF16Length: max(0, scanned.scannedEnd - restart.offset),
                generatedTokenCount: scanned.tokens.count,
                reusedPrefixTokenCount: prefix.count,
                reusedSuffixTokenCount: suffix.count,
                converged: scanned.stoppedForConvergence,
                incremental: true))
    }

    public mutating func reset() { previous = nil }

    private mutating func fullTokenize(_ snapshot: SourceSnapshot) -> IncrementalLexResult {
        let lexed = PL0Lexer(languageKit: languageKit).tokenize(snapshot)
        previous = State(version: snapshot.version, text: snapshot.text, lexed: lexed)
        return IncrementalLexResult(
            version: snapshot.version,
            lexed: lexed,
            metrics: IncrementalLexMetrics(
                scannedUTF16Length: snapshot.text.utf16.count,
                generatedTokenCount: lexed.tokens.count,
                reusedPrefixTokenCount: 0,
                reusedSuffixTokenCount: 0,
                converged: false,
                incremental: false))
    }

    private func isConsistent(edit: SourceEdit, oldText: String, newText: String) -> Bool {
        let oldLength = oldText.utf16.count
        let range = edit.replacedRange
        return range.location >= 0
            && range.length >= 0
            && range.end <= oldLength
            && edit.replacementLength >= 0
            && oldLength - range.length + edit.replacementLength == newText.utf16.count
    }

    private func relocate(_ token: PL0Token, delta: Int,
                          oldAnchor: PL0Token, newAnchor: PL0Token) -> PL0Token {
        let line: Int
        let column: Int
        if token.location.line == oldAnchor.location.line {
            line = newAnchor.location.line
            column = newAnchor.location.column
                + token.location.column - oldAnchor.location.column
        } else {
            line = newAnchor.location.line + token.location.line - oldAnchor.location.line
            column = token.location.column
        }
        let offset = token.range.location + delta
        return PL0Token(id: token.id, kind: token.kind, lexeme: token.lexeme,
                        range: SourceRange(location: offset, length: token.range.length),
                        location: SourceLocation(offset: offset, line: line, column: column))
    }

    private func relocate(_ diagnostic: ParseDiagnostic, delta: Int) -> ParseDiagnostic {
        ParseDiagnostic(severity: diagnostic.severity, message: diagnostic.message,
                        range: SourceRange(location: diagnostic.range.location + delta,
                                           length: diagnostic.range.length))
    }

    private func relocate(_ token: PL0LosslessToken, delta: Int,
                          oldAnchor: PL0Token, newAnchor: PL0Token) -> PL0LosslessToken {
        let line: Int
        let column: Int
        if token.location.line == oldAnchor.location.line {
            line = newAnchor.location.line
            column = newAnchor.location.column
                + token.location.column - oldAnchor.location.column
        } else {
            line = newAnchor.location.line + token.location.line - oldAnchor.location.line
            column = token.location.column
        }
        let offset = token.range.location + delta
        return PL0LosslessToken(
            id: token.id, kind: token.kind, lexeme: token.lexeme,
            range: SourceRange(location: offset, length: token.range.length),
            location: SourceLocation(offset: offset, line: line, column: column))
    }
}
