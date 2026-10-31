import Foundation

public enum PL0FormatterError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidSource([ParseDiagnostic])

    public var description: String {
        switch self {
        case let .invalidSource(diagnostics):
            diagnostics.first?.message ?? "PL/0 source contains syntax errors"
        }
    }
}

/// Deterministic formatter for the controlled PL/0 grammar. Comments are
/// collected from lexer trivia and re-emitted in source order; malformed input
/// is left untouched rather than formatting a recovered tree.
public struct PL0Formatter: Sendable {
    public let indentationWidth: Int
    private let frontend: PL0Frontend

    public init(indentationWidth: Int = 2) {
        self.init(indentationWidth: indentationWidth, frontend: PL0Frontend())
    }

    public init(indentationWidth: Int = 2, frontend: PL0Frontend) {
        self.indentationWidth = max(1, indentationWidth)
        self.frontend = frontend
    }

    public func format(_ source: String) throws -> String {
        try format(frontend.prepare(SourceSnapshot(version: 0, text: source)))
    }

    public func format(_ prepared: PL0PreparedFrontend) throws -> String {
        let parsed = frontend.parse(prepared)
        guard parsed.diagnostics.isEmpty else {
            throw PL0FormatterError.invalidSource(parsed.diagnostics)
        }

        let tokens = parsed.tokens.filter { $0.kind != .endOfFile }
        let comments = parsed.losslessTokens.compactMap { token -> Comment? in
            switch token.kind {
            case .trivia(.lineComment), .trivia(.blockComment):
                Comment(range: token.range, text: token.lexeme)
            default:
                nil
            }
        }
        let items = (tokens.map { Item(offset: $0.range.location, value: .token($0)) }
            + comments.map { Item(offset: $0.range.location, value: .comment($0.text)) })
            .sorted { lhs, rhs in lhs.offset < rhs.offset }

        var writer = Writer(indentationWidth: indentationWidth)
        for item in items {
            switch item.value {
            case let .token(token): writer.write(token)
            case let .comment(comment): writer.write(comment: comment)
            }
        }
        return writer.finish()
    }

    private struct Comment {
        let range: SourceRange
        let text: String
    }

    private enum ItemValue {
        case token(PL0Token)
        case comment(String)
    }

    private struct Item {
        let offset: Int
        let value: ItemValue
    }

}

private struct Writer {
    let indentationWidth: Int
    private var indentation = 0
    private var lines: [String] = []
    private var current = ""
    private var previousKind: PL0TokenKind?
    private var unarySignPending = false

    init(indentationWidth: Int) { self.indentationWidth = indentationWidth }

    mutating func write(_ token: PL0Token) {
        switch token.kind {
        case .begin:
            word(token.lexeme)
            newline()
            indentation += 1
        case .end:
            newline()
            indentation = max(0, indentation - 1)
            word(token.lexeme)
        case .semicolon:
            trimTrailingSpace()
            append(";")
            newline()
        case .period:
            trimTrailingSpace()
            append(".")
            newline()
        case .comma:
            trimTrailingSpace()
            append(", ")
        case .leftParen:
            if previousKind == .identifier || previousKind == .number { space() }
            append("(")
        case .rightParen:
            trimTrailingSpace()
            append(")")
        case .plus, .minus:
            if isUnarySignPosition {
                if current.last != "(" { space() }
                append(token.lexeme)
                unarySignPending = true
            } else {
                space(); append(token.lexeme); space()
            }
        case .assign, .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual,
             .star, .slash:
            space(); append(token.lexeme); space()
        case .const, .varKeyword, .procedure:
            if !current.trimmingCharacters(in: .whitespaces).isEmpty { newline() }
            word(token.lexeme)
        case .identifier, .number, .call, .ifKeyword, .then, .whileKeyword,
             .doKeyword, .odd:
            word(token.lexeme)
        case .invalid, .endOfFile:
            break
        }
        previousKind = token.kind
    }

    mutating func write(comment: String) {
        if comment.hasPrefix("//") {
            space(); append(comment.trimmingCharacters(in: .whitespacesAndNewlines))
            newline()
            return
        }
        if comment.contains("\n") || comment.contains("\r") {
            newline()
            for line in comment.components(separatedBy: .newlines) {
                append(line.trimmingCharacters(in: .whitespaces))
                newline()
            }
        } else {
            space(); append(comment); space()
        }
    }

    mutating func finish() -> String {
        newline()
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    private mutating func word(_ text: String) {
        if unarySignPending {
            append(text)
            unarySignPending = false
            return
        }
        if let last = current.last, !last.isWhitespace, last != "(" { space() }
        append(text)
    }

    private var isUnarySignPosition: Bool {
        guard let previousKind else { return true }
        return [.assign, .equal, .notEqual, .less, .lessEqual, .greater,
                .greaterEqual, .leftParen, .plus, .minus].contains(previousKind)
    }

    private mutating func append(_ text: String) {
        if current.isEmpty { current = String(repeating: " ", count: indentation * indentationWidth) }
        current += text
    }

    private mutating func space() {
        guard !current.isEmpty, current.last?.isWhitespace == false else { return }
        current.append(" ")
    }

    private mutating func trimTrailingSpace() {
        while current.last?.isWhitespace == true { current.removeLast() }
    }

    private mutating func newline() {
        trimTrailingSpace()
        guard !current.isEmpty else { return }
        lines.append(current)
        current = ""
        previousKind = nil
        unarySignPending = false
    }
}
