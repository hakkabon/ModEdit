import Foundation

/// How a terminal participates in the recovered concrete token stream.
public enum CSTTerminalDisposition: String, Sendable {
    /// A lexer token accepted by the parser.
    case source
    /// A zero-width terminal synthesized by parser recovery.
    case missing
    /// A lexer token rejected while synchronizing the parser.
    case skipped
}

/// Parser-neutral terminal representation used alongside the structural CST.
/// It retains spelling and source coordinates while making recovery artifacts
/// explicit instead of pretending inserted or deleted tokens never existed.
public struct CSTTerminal: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: PL0TokenKind
    public let lexeme: String
    public let range: SourceRange
    public let location: SourceLocation
    public let disposition: CSTTerminalDisposition

    public init(id: String, kind: PL0TokenKind, lexeme: String,
                range: SourceRange, location: SourceLocation,
                disposition: CSTTerminalDisposition) {
        self.id = id
        self.kind = kind
        self.lexeme = lexeme
        self.range = range
        self.location = location
        self.disposition = disposition
    }

    /// Independent parser runs may assign different identities to otherwise
    /// identical terminals, so equality describes concrete syntax structure.
    public static func == (lhs: CSTTerminal, rhs: CSTTerminal) -> Bool {
        lhs.kind == rhs.kind
            && lhs.lexeme == rhs.lexeme
            && lhs.range == rhs.range
            && lhs.location == rhs.location
            && lhs.disposition == rhs.disposition
    }
}

/// A normalized concrete syntax tree for comparing different parser engines.
/// `root` describes grammatical nesting; `terminals` is the complete ordered
/// token stream after recovery, including missing and skipped terminals.
public struct ConcreteSyntaxTree: Sendable, Equatable {
    public let root: SyntaxNode
    public let terminals: [CSTTerminal]

    public init(root: SyntaxNode, sourceTokens: [PL0Token],
                recoveryActions: [RecoveryAction] = []) {
        self.root = root
        terminals = Self.makeTerminals(from: sourceTokens, actions: recoveryActions)
    }

    public var missingTerminals: [CSTTerminal] {
        terminals.filter { $0.disposition == .missing }
    }

    public var skippedTerminals: [CSTTerminal] {
        terminals.filter { $0.disposition == .skipped }
    }

    /// Returns the concrete terminals covered by a grammatical node. Missing
    /// terminals are zero-width and belong to a node when their insertion point
    /// lies within its closed source span.
    public func terminals(in node: SyntaxNode) -> [CSTTerminal] {
        terminals.filter { terminal in
            if terminal.disposition == .missing {
                return terminal.range.location >= node.range.location
                    && terminal.range.location <= node.range.end
            }
            return terminal.range.location >= node.range.location
                && terminal.range.end <= node.range.end
        }
    }

    public func outline() -> String {
        let terminalLines = terminals.map { terminal in
            let marker = switch terminal.disposition {
            case .source: ""
            case .missing: " [missing]"
            case .skipped: " [skipped]"
            }
            let spelling = terminal.lexeme.isEmpty
                ? terminal.kind.displayName
                : "\"\(terminal.lexeme.replacingOccurrences(of: "\n", with: "\\n"))\""
            return "  \(terminal.kind.rawValue) \(spelling) @\(terminal.range.location)..<\(terminal.range.end)\(marker)"
        }
        return ([root.outline(), "Terminals"] + terminalLines).joined(separator: "\n")
    }

    private struct PositionedTerminal {
        let terminal: CSTTerminal
        let actionOrder: Int
    }

    private static func makeTerminals(from tokens: [PL0Token],
                                      actions: [RecoveryAction]) -> [CSTTerminal] {
        let deletedIDs = Set(actions.compactMap { action -> String? in
            if case let .delete(token) = action { return token.id }
            return nil
        })
        var positioned = tokens
            .filter { $0.kind != .endOfFile }
            .enumerated()
            .map { index, token in
                PositionedTerminal(
                    terminal: CSTTerminal(
                        id: token.id, kind: token.kind, lexeme: token.lexeme,
                        range: token.range, location: token.location,
                        disposition: deletedIDs.contains(token.id) ? .skipped : .source),
                    actionOrder: index * 2 + 1)
            }

        for (index, action) in actions.enumerated() {
            guard case let .insert(kind, offset) = action else { continue }
            let location = insertionLocation(at: offset, tokens: tokens)
            positioned.append(PositionedTerminal(
                terminal: CSTTerminal(
                    id: "missing:\(index):\(kind.rawValue):\(offset)",
                    kind: kind, lexeme: "",
                    range: SourceRange(location: offset, length: 0),
                    location: location, disposition: .missing),
                actionOrder: index * 2))
        }

        return positioned.sorted { lhs, rhs in
            if lhs.terminal.range.location != rhs.terminal.range.location {
                return lhs.terminal.range.location < rhs.terminal.range.location
            }
            if lhs.terminal.disposition != rhs.terminal.disposition {
                return lhs.terminal.disposition == .missing
            }
            return lhs.actionOrder < rhs.actionOrder
        }.map(\.terminal)
    }

    private static func insertionLocation(at offset: Int,
                                          tokens: [PL0Token]) -> SourceLocation {
        if let following = tokens.first(where: { $0.range.location >= offset }) {
            return SourceLocation(offset: offset, line: following.location.line,
                                  column: following.location.column)
        }
        guard let last = tokens.last else {
            return SourceLocation(offset: offset, line: 1, column: 1)
        }
        return SourceLocation(offset: offset, line: last.location.line,
                              column: last.location.column)
    }
}
