import Foundation

public struct ParserCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let deterministicTree = ParserCapabilities(rawValue: 1 << 0)
    public static let errorRecovery = ParserCapabilities(rawValue: 1 << 1)
    public static let expectedTokens = ParserCapabilities(rawValue: 1 << 2)
    public static let incremental = ParserCapabilities(rawValue: 1 << 3)
    public static let ambiguity = ParserCapabilities(rawValue: 1 << 4)
}

public struct ParserDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let capabilities: ParserCapabilities

    public init(id: String, displayName: String, capabilities: ParserCapabilities) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
    }
}

public struct ParseExpectation: Sendable, Equatable, Identifiable {
    public let offset: Int
    public let kinds: [PL0TokenKind]
    public var id: String { "\(offset):\(kinds.map(\.rawValue).joined(separator: ","))" }

    public init(offset: Int, kinds: [PL0TokenKind]) {
        self.offset = offset
        self.kinds = kinds
    }
}

public struct ParserInput: Sendable {
    public let tokens: [PL0Token]
    public let lexicalDiagnostics: [ParseDiagnostic]
    /// Original source when available. Ecosystem parsers consume positioned
    /// token streams and use this text to retain editor-compatible ranges.
    public let source: String?

    public init(tokens: [PL0Token], lexicalDiagnostics: [ParseDiagnostic],
                source: String? = nil) {
        self.tokens = tokens
        self.lexicalDiagnostics = lexicalDiagnostics
        self.source = source
    }
}

public struct ParserReuseMetrics: Sendable, Equatable {
    public let reusedNodeCount: Int
    public let reusedTokenCount: Int
    public let parsedNodeCount: Int
    public let incremental: Bool

    public init(reusedNodeCount: Int, reusedTokenCount: Int,
                parsedNodeCount: Int, incremental: Bool) {
        self.reusedNodeCount = reusedNodeCount
        self.reusedTokenCount = reusedTokenCount
        self.parsedNodeCount = parsedNodeCount
        self.incremental = incremental
    }

    public static let fullParse = ParserReuseMetrics(
        reusedNodeCount: 0, reusedTokenCount: 0,
        parsedNodeCount: 0, incremental: false)
}

public struct ParserOutput: Sendable {
    public let syntaxTree: ConcreteSyntaxTree
    public let diagnostics: [ParseDiagnostic]
    public let recovery: RecoveryModel
    public let reuseMetrics: ParserReuseMetrics

    public var root: SyntaxNode { syntaxTree.root }
    public var recoveryActions: [RecoveryAction] { recovery.actions }
    public var expectations: [ParseExpectation] { recovery.expectations }

    public init(syntaxTree: ConcreteSyntaxTree, diagnostics: [ParseDiagnostic],
                recovery: RecoveryModel,
                reuseMetrics: ParserReuseMetrics = .fullParse) {
        self.syntaxTree = syntaxTree
        self.diagnostics = diagnostics
        self.recovery = recovery
        self.reuseMetrics = reuseMetrics
    }
}

/// Common contract for the reference parser and future generated/generalized
/// engines. A parser receives an immutable token snapshot and returns only
/// immutable, parser-neutral values.
public protocol PL0ParserProtocol: Sendable {
    var descriptor: ParserDescriptor { get }
    func parse(_ input: ParserInput) -> ParserOutput
}
