import Foundation

public enum DiagnosticSeverity: String, Sendable {
    case error, warning, information
}

public struct ParseDiagnostic: Sendable, Equatable, Identifiable {
    public let id: String
    public let severity: DiagnosticSeverity
    public let message: String
    public let range: SourceRange
    public let expected: [PL0TokenKind]

    public init(severity: DiagnosticSeverity, message: String, range: SourceRange,
                expected: [PL0TokenKind] = []) {
        self.id = "\(range.location):\(range.length):\(message)"
        self.severity = severity
        self.message = message
        self.range = range
        self.expected = expected
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

    public var range: SourceRange {
        switch self {
        case let .insert(_, offset): SourceRange(location: offset, length: 0)
        case let .delete(token): token.range
        }
    }

    public var cost: Int { 1 }
}

/// One ordered and inspectable recovery decision. Diagnostic IDs make the
/// relationship between the user-facing problem and the parser repair explicit.
public struct RecoveryEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let sequence: Int
    public let action: RecoveryAction
    public let expected: [PL0TokenKind]
    public let diagnosticIDs: [String]
    public let cost: Int

    public init(sequence: Int, action: RecoveryAction,
                expected: [PL0TokenKind], diagnosticIDs: [String], cost: Int) {
        self.id = "\(sequence):\(action.range.location):\(action.summary)"
        self.sequence = sequence
        self.action = action
        self.expected = expected
        self.diagnosticIDs = diagnosticIDs
        self.cost = cost
    }
}

/// Parser-neutral recovery result suitable for comparing deterministic and
/// generalized engines by repair sequence, expectations and aggregate cost.
public struct RecoveryModel: Sendable, Equatable {
    public let events: [RecoveryEvent]
    public let expectations: [ParseExpectation]

    public init(actions: [RecoveryAction], expectations: [ParseExpectation],
                diagnostics: [ParseDiagnostic]) {
        self.expectations = expectations
        events = actions.enumerated().map { sequence, action in
            let offset = action.range.location
            var expected = expectations
                .filter { $0.offset == offset }
                .flatMap(\.kinds)
            if case let .insert(kind, _) = action, !expected.contains(kind) {
                expected.append(kind)
            }
            let diagnosticIDs = diagnostics.filter {
                $0.range.location == offset
            }.map(\.id)
            return RecoveryEvent(sequence: sequence, action: action,
                                 expected: expected, diagnosticIDs: diagnosticIDs,
                                 cost: action.cost)
        }
    }

    public var isClean: Bool { events.isEmpty }
    public var totalCost: Int { events.reduce(0) { $0 + $1.cost } }
    public var insertionCount: Int {
        events.count { if case .insert = $0.action { true } else { false } }
    }
    public var deletionCount: Int {
        events.count { if case .delete = $0.action { true } else { false } }
    }

    public var actions: [RecoveryAction] { events.map(\.action) }
}
