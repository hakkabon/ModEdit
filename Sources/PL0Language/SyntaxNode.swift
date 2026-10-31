import Foundation
import LanguageExperimentProtocol

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

    public init(id: String? = nil, kind: String, range: SourceRange,
                origin: SyntaxOrigin = .source,
                children: [SyntaxNode] = []) {
        // Identity describes this particular parse node, not merely its shape.
        // Cached nodes retain the ID through `relocated(by:)`; a freshly parsed
        // node receives a new one even when an edit leaves its range unchanged.
        self.id = id ?? UUID().uuidString
        self.kind = kind
        self.range = range
        self.origin = origin
        self.children = children
    }

    public var nodeCount: Int {
        1 + children.reduce(0) { $0 + $1.nodeCount }
    }

    /// Tree equality is structural. `id` is deliberately excluded because it
    /// records reuse identity, while independent full parses of the same source
    /// must still compare equal as syntax results.
    public static func == (lhs: SyntaxNode, rhs: SyntaxNode) -> Bool {
        lhs.kind == rhs.kind
            && lhs.range == rhs.range
            && lhs.origin == rhs.origin
            && lhs.children == rhs.children
    }

    /// Moves a cached subtree after an edit before it while retaining syntax
    /// identities. A cache entry is reused only when every consumed token and
    /// its lookahead retain their identities, so all ranges move uniformly.
    public func relocated(by delta: Int) -> SyntaxNode {
        guard delta != 0 else { return self }
        return SyntaxNode(
            id: id, kind: kind,
            range: SourceRange(location: range.location + delta, length: range.length),
            origin: origin,
            children: children.map { $0.relocated(by: delta) })
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
    public let incrementalLexing: IncrementalLexMetrics
    public let incrementalParsing: ParserReuseMetrics

    public init(sourceLength: Int, tokenCount: Int, lexingNanoseconds: UInt64,
                parsingNanoseconds: UInt64, recoveryCount: Int,
                incrementalLexing: IncrementalLexMetrics,
                incrementalParsing: ParserReuseMetrics) {
        self.sourceLength = sourceLength
        self.tokenCount = tokenCount
        self.lexingNanoseconds = lexingNanoseconds
        self.parsingNanoseconds = parsingNanoseconds
        self.recoveryCount = recoveryCount
        self.incrementalLexing = incrementalLexing
        self.incrementalParsing = incrementalParsing
    }
}

public struct ParseResult: Sendable, Equatable {
    public let version: UInt64
    public let parser: ParserDescriptor
    public let grammarArtifact: GrammarArtifactIdentity
    public let tokens: [PL0Token]
    public let losslessTokens: [PL0LosslessToken]
    public let syntaxTree: ConcreteSyntaxTree
    public let diagnostics: [ParseDiagnostic]
    public let recovery: RecoveryModel
    public let metrics: ParseMetrics
    public let algorithmArtifact: ParserAlgorithmArtifact?

    public var root: SyntaxNode { syntaxTree.root }
    public var recoveryActions: [RecoveryAction] { recovery.actions }
    public var expectations: [ParseExpectation] { recovery.expectations }

    public init(version: UInt64, parser: ParserDescriptor,
                grammarArtifact: GrammarArtifactIdentity = PL0LanguageKit.bundled.artifact.grammarIdentity,
                tokens: [PL0Token], losslessTokens: [PL0LosslessToken] = [],
                syntaxTree: ConcreteSyntaxTree,
                diagnostics: [ParseDiagnostic], recovery: RecoveryModel,
                metrics: ParseMetrics,
                algorithmArtifact: ParserAlgorithmArtifact? = nil) {
        self.version = version
        self.parser = parser
        self.grammarArtifact = grammarArtifact
        self.tokens = tokens
        self.losslessTokens = losslessTokens
        self.syntaxTree = syntaxTree
        self.diagnostics = diagnostics
        self.recovery = recovery
        self.metrics = metrics
        self.algorithmArtifact = algorithmArtifact
    }
}
