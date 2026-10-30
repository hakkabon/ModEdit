import Foundation

public enum SyntaxOrigin: String, Sendable {
    case source
    case recovered
}

/// A deliberately parser-neutral concrete syntax tree. Future LL, LR, Earley
/// and RNGLR adapters can all normalize into this representation.
public struct SyntaxNode: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let range: SourceRange
    public let origin: SyntaxOrigin
    public let children: [SyntaxNode]

    public init(kind: String, range: SourceRange, origin: SyntaxOrigin = .source,
                children: [SyntaxNode] = []) {
        self.id = "\(kind):\(range.location):\(range.length):\(origin.rawValue)"
        self.kind = kind
        self.range = range
        self.origin = origin
        self.children = children
    }

    public func outline(indentation: String = "") -> String {
        let marker = origin == .recovered ? " [recovered]" : ""
        let current = "\(indentation)\(kind) @\(range.location)..<\(range.end)\(marker)"
        guard !children.isEmpty else { return current }
        return ([current] + children.map { $0.outline(indentation: indentation + "  ") })
            .joined(separator: "\n")
    }
}

public struct ParseMetrics: Sendable, Equatable {
    public let sourceLength: Int
    public let tokenCount: Int
    public let lexingNanoseconds: UInt64
    public let parsingNanoseconds: UInt64
    public let recoveryCount: Int

    public init(sourceLength: Int, tokenCount: Int, lexingNanoseconds: UInt64,
                parsingNanoseconds: UInt64, recoveryCount: Int) {
        self.sourceLength = sourceLength
        self.tokenCount = tokenCount
        self.lexingNanoseconds = lexingNanoseconds
        self.parsingNanoseconds = parsingNanoseconds
        self.recoveryCount = recoveryCount
    }
}

public struct ParseResult: Sendable, Equatable {
    public let version: UInt64
    public let tokens: [PL0Token]
    public let root: SyntaxNode
    public let diagnostics: [ParseDiagnostic]
    public let recoveryActions: [RecoveryAction]
    public let metrics: ParseMetrics

    public init(version: UInt64, tokens: [PL0Token], root: SyntaxNode,
                diagnostics: [ParseDiagnostic], recoveryActions: [RecoveryAction],
                metrics: ParseMetrics) {
        self.version = version
        self.tokens = tokens
        self.root = root
        self.diagnostics = diagnostics
        self.recoveryActions = recoveryActions
        self.metrics = metrics
    }
}
