import Foundation

public enum DiagnosticSeverity: String, Sendable {
    case error, warning, information
}

public struct ParseDiagnostic: Sendable, Equatable, Identifiable {
    public let id: String
    public let severity: DiagnosticSeverity
    public let message: String
    public let range: SourceRange

    public init(severity: DiagnosticSeverity, message: String, range: SourceRange) {
        self.id = "\(range.location):\(range.length):\(message)"
        self.severity = severity
        self.message = message
        self.range = range
    }
}

public enum RecoveryAction: Sendable, Equatable {
    case insert(kind: PL0TokenKind, at: Int)
    case delete(token: PL0Token)

    public var summary: String {
        switch self {
        case let .insert(kind, offset): "insert \(kind.displayName) at \(offset)"
        case let .delete(token): "delete '\(token.lexeme)' at \(token.range.location)"
        }
    }
}
