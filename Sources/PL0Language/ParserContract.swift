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

    public init(tokens: [PL0Token], lexicalDiagnostics: [ParseDiagnostic]) {
        self.tokens = tokens
        self.lexicalDiagnostics = lexicalDiagnostics
    }
}

public struct ParserOutput: Sendable {
    public let root: SyntaxNode
    public let diagnostics: [ParseDiagnostic]
    public let recoveryActions: [RecoveryAction]
    public let expectations: [ParseExpectation]

    public init(root: SyntaxNode, diagnostics: [ParseDiagnostic],
                recoveryActions: [RecoveryAction], expectations: [ParseExpectation]) {
        self.root = root
        self.diagnostics = diagnostics
        self.recoveryActions = recoveryActions
        self.expectations = expectations
    }
}

/// Common contract for the reference parser and future generated/generalized
/// engines. A parser receives an immutable token snapshot and returns only
/// immutable, parser-neutral values.
public protocol PL0ParserProtocol: Sendable {
    var descriptor: ParserDescriptor { get }
    func parse(_ input: ParserInput) -> ParserOutput
}
