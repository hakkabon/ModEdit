import Foundation

public enum PL0TokenKind: String, Sendable, CaseIterable {
    case identifier, number
    case const, varKeyword = "var", procedure, call, begin, end
    case ifKeyword = "if", then, whileKeyword = "while", doKeyword = "do", odd
    case plus, minus, star, slash
    case equal, notEqual, less, lessEqual, greater, greaterEqual
    case assign, comma, semicolon, period, leftParen, rightParen
    case invalid, endOfFile

    public var isRelationalOperator: Bool {
        switch self {
        case .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual: true
        default: false
        }
    }

    public var displayName: String {
        switch self {
        case .identifier: "identifier"
        case .number: "number"
        case .varKeyword: "'var'"
        case .ifKeyword: "'if'"
        case .whileKeyword: "'while'"
        case .doKeyword: "'do'"
        case .endOfFile: "end of file"
        default: "'\(rawValue)'"
        }
    }
}

/// Tokens retain source spelling and location. The identity is deterministic
/// for a snapshot; incremental lexing can later preserve it for reused tokens.
public struct PL0Token: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: PL0TokenKind
    public let lexeme: String
    public let range: SourceRange
    public let location: SourceLocation

    public init(kind: PL0TokenKind, lexeme: String, range: SourceRange,
                location: SourceLocation) {
        self.id = "\(range.location):\(kind.rawValue):\(lexeme)"
        self.kind = kind
        self.lexeme = lexeme
        self.range = range
        self.location = location
    }
}
