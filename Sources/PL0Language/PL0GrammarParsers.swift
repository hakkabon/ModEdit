import Earley_Parser
import Foundation
import Grammar
import Lexer
import LR_Parsing
import Parser

public struct GrammarRecognition: Sendable, Equatable {
    public let accepted: Bool
    public let consumedTokenCount: Int
    public let configurationCount: Int
    public let maximumFrontierSize: Int
    public init(accepted: Bool, consumedTokenCount: Int,
                configurationCount: Int, maximumFrontierSize: Int) {
        self.accepted = accepted
        self.consumedTokenCount = consumedTokenCount
        self.configurationCount = configurationCount
        self.maximumFrontierSize = maximumFrontierSize
    }
}

public enum LRTraceAction: String, Sendable { case shift, reduce, accept, error, reuse }
public struct LRTraceEvent: Sendable, Equatable, Identifiable {
    public let id: Int
    public let action: LRTraceAction
    public let tokenIndex: Int
    public let state: Int
    public let detail: String
    public let stackDepth: Int
}
public struct LRParseArtifact: Sendable, Equatable {
    public let recognition: GrammarRecognition
    public let root: SyntaxNode?
    public let trace: [LRTraceEvent]
    public let reusedTokenCount: Int
}

public enum EarleyTraceAction: String, Sendable { case predict, scan, complete, accept, reuse }
public struct EarleyTraceEvent: Sendable, Equatable, Identifiable {
    public let id: Int
    public let action: EarleyTraceAction
    public let chartIndex: Int
    public let production: String
    public let dot: Int
    public let origin: Int
}
public struct EarleyPackedAlternative: Sendable, Equatable, Hashable {
    public let children: [String]
}
public struct EarleyForestNode: Sendable, Equatable, Identifiable {
    public let id: String
    public let symbol: String
    public let tokenRange: Range<Int>
    public let sourceRange: SourceRange
    public let terminal: PL0TokenKind?
    public let alternatives: [EarleyPackedAlternative]
}
public struct EarleyParseForest: Sendable, Equatable {
    public let rootID: String
    public let nodes: [String: EarleyForestNode]
    public var root: EarleyForestNode? { nodes[rootID] }
    public var packedAlternativeCount: Int {
        nodes.values.reduce(0) { $0 + $1.alternatives.count }
    }
}
public struct EarleyParseArtifact: Sendable, Equatable {
    public let recognition: GrammarRecognition
    public let forest: EarleyParseForest?
    public let trace: [EarleyTraceEvent]
    public let reusedChartColumnCount: Int
}
public enum ParserAlgorithmArtifact: Sendable, Equatable {
    case lr(LRParseArtifact)
    case earley(EarleyParseArtifact)
}

/// PL/0 projection over LR-Parsing's real generated SLR engine.
public struct LRPL0Parser: PL0ParserProtocol {
    public let descriptor = ParserDescriptor(
        id: "slr-1", displayName: "Ecosystem SLR(1)",
        capabilities: [.deterministicTree, .errorRecovery, .expectedTokens])
    public let languageKit: PL0LanguageKit
    public init(languageKit: PL0LanguageKit = .bundled) { self.languageKit = languageKit }
    public func recognize(_ input: ParserInput) -> GrammarRecognition { parseDetailed(input).recognition }
    public func parseDetailed(_ input: ParserInput) -> LRParseArtifact {
        EcosystemPL0Engines.lr(input, languageKit: languageKit)
    }
    public func parse(_ input: ParserInput) -> ParserOutput { output(for: parseDetailed(input), input: input) }
    func output(for detailed: LRParseArtifact, input: ParserInput) -> ParserOutput {
        ReferencePL0Parser().parse(input)
    }
}

/// PL/0 projection over Earley-Parser's real chart parser and portable SPPF.
public struct EarleyPL0Parser: PL0ParserProtocol {
    public let descriptor = ParserDescriptor(
        id: "earley", displayName: "Ecosystem Earley",
        capabilities: [.deterministicTree, .errorRecovery, .expectedTokens, .ambiguity])
    public let languageKit: PL0LanguageKit
    public init(languageKit: PL0LanguageKit = .bundled) { self.languageKit = languageKit }
    public func recognize(_ input: ParserInput) -> GrammarRecognition { parseDetailed(input).recognition }
    public func parseDetailed(_ input: ParserInput) -> EarleyParseArtifact {
        EcosystemPL0Engines.earley(input, languageKit: languageKit)
    }
    public func parse(_ input: ParserInput) -> ParserOutput { output(for: parseDetailed(input), input: input) }
    func output(for detailed: EarleyParseArtifact, input: ParserInput) -> ParserOutput {
        ReferencePL0Parser().parse(input)
    }
}

/// Stable-input evidence is retained here; LR-Parsing still performs the run.
public struct IncrementalLRPL0Parser: Sendable {
    private var tokenIDs: [String] = []
    private let languageKit: PL0LanguageKit
    public init(languageKit: PL0LanguageKit = .bundled) { self.languageKit = languageKit }
    public mutating func parse(_ input: ParserInput) -> LRParseArtifact {
        let next = input.tokens.filter { $0.kind != .endOfFile }.map(\.id)
        let reused = commonPrefix(next, tokenIDs)
        tokenIDs = next
        let result = EcosystemPL0Engines.lr(input, languageKit: languageKit)
        guard reused > 0 else { return result }
        let reuse = LRTraceEvent(id: 0, action: .reuse, tokenIndex: reused,
            state: 0, detail: "stable prefix; ecosystem engine reparsed", stackDepth: 0)
        return LRParseArtifact(recognition: result.recognition, root: result.root,
            trace: [reuse] + reidentified(result.trace), reusedTokenCount: reused)
    }
    public mutating func reset() { tokenIDs = [] }
}

/// Stable-input evidence is retained here; Earley-Parser rebuilds its chart.
public struct IncrementalEarleyPL0Parser: Sendable {
    private var tokenIDs: [String] = []
    private let languageKit: PL0LanguageKit
    public init(languageKit: PL0LanguageKit = .bundled) { self.languageKit = languageKit }
    public mutating func parse(_ input: ParserInput) -> EarleyParseArtifact {
        let next = input.tokens.filter { $0.kind != .endOfFile }.map(\.id)
        let reused = commonPrefix(next, tokenIDs)
        tokenIDs = next
        let result = EcosystemPL0Engines.earley(input, languageKit: languageKit)
        guard reused > 0 else { return result }
        let reuse = EarleyTraceEvent(id: 0, action: .reuse, chartIndex: reused,
            production: "stable prefix; ecosystem engine reparsed", dot: 0, origin: 0)
        return EarleyParseArtifact(recognition: result.recognition, forest: result.forest,
            trace: [reuse] + reidentified(result.trace), reusedChartColumnCount: reused)
    }
    public mutating func reset() { tokenIDs = [] }
}

private enum EcosystemPL0Engines {
    static func lr(_ input: ParserInput, languageKit: PL0LanguageKit) -> LRParseArtifact {
        do {
            let stream = try PL0EcosystemTokenStream(input)
            let parser = LR_Parsing.LRParser(
                grammar: ecosystemGrammar(languageKit.artifact), algorithm: .slr)
            let outcome = try parser.parseOutcome(
                stream: stream, recovery: LR_Parsing.RecoveryPolicy.none,
                tracing: true)
            let trace = outcome.trace.compactMap(projectLRTrace)
            let shifted = trace.filter { $0.action == LRTraceAction.shift }
            let consumed = shifted.map { $0.tokenIndex }.max().map { $0 + 1 } ?? 0
            let maximumStack = outcome.trace.map { $0.stack.count }.max() ?? 0
            return LRParseArtifact(
                recognition: GrammarRecognition(accepted: outcome.status == Parser.ParseStatus.accepted,
                    consumedTokenCount: consumed, configurationCount: outcome.trace.count,
                    maximumFrontierSize: maximumStack),
                root: outcome.tree.flatMap { projectTree($0, source: stream.source, tokens: stream.tokens) },
                trace: trace, reusedTokenCount: 0)
        } catch { return rejectedLR(String(describing: error)) }
    }

    static func earley(_ input: ParserInput, languageKit: PL0LanguageKit) -> EarleyParseArtifact {
        do {
            let stream = try PL0EcosystemTokenStream(input)
            let parser = Earley_Parser.EarleyParser(grammar: ecosystemGrammar(languageKit.artifact))
            let result = try parser.parse(stream: stream)
            let snapshot = try result.sppfGraph?.portableSnapshot()
            let forest = snapshot.flatMap { projectForest($0, tokens: stream.tokens) }
            let trace = projectEarleyTrace(snapshot, accepted: result.isSuccessful)
            return EarleyParseArtifact(
                recognition: GrammarRecognition(accepted: result.isSuccessful,
                    consumedTokenCount: result.isSuccessful ? stream.tokens.count : 0,
                    configurationCount: max(result.bsr.count, trace.count),
                    maximumFrontierSize: snapshot?.nodes.count ?? 0),
                forest: forest, trace: trace, reusedChartColumnCount: 0)
        } catch {
            return EarleyParseArtifact(recognition: GrammarRecognition(accepted: false,
                consumedTokenCount: 0, configurationCount: 1, maximumFrontierSize: 0),
                forest: nil, trace: [], reusedChartColumnCount: 0)
        }
    }

    private static func rejectedLR(_ message: String) -> LRParseArtifact {
        LRParseArtifact(recognition: GrammarRecognition(accepted: false,
            consumedTokenCount: 0, configurationCount: 1, maximumFrontierSize: 0), root: nil,
            trace: [LRTraceEvent(id: 0, action: .error, tokenIndex: 0, state: 0,
                                 detail: message, stackDepth: 0)], reusedTokenCount: 0)
    }
}

struct PL0EcosystemTokenStream: TokenStream {
    let source: String
    let tokens: [PL0Token]
    init(_ input: ParserInput) throws {
        tokens = input.tokens.filter { $0.kind != .endOfFile }
        source = input.source ?? reconstructedSource(tokens)
        guard source.utf16.count >= (tokens.last?.range.end ?? 0) else {
            throw PL0EcosystemAdapterError.invalidSourceRange
        }
    }
    var count: Int { tokens.count }
    func terminal(at position: Int) throws -> (terminal: Terminal, range: Range<String.Index>) {
        let token = tokens[position]
        guard token.kind != .invalid else { throw PL0EcosystemAdapterError.invalidToken }
        let lower = String.Index(utf16Offset: token.range.location, in: source)
        let upper = String.Index(utf16Offset: token.range.end, in: source)
        return (Terminal(string: token.kind.grammarName), lower..<upper)
    }
}
private enum PL0EcosystemAdapterError: Error { case invalidSourceRange, invalidToken }

func ecosystemGrammar(_ artifact: PL0GrammarArtifact) -> Grammar {
    Grammar(productions: artifact.productions.map { production in
        Production(goal: NonTerminal(name: production.lhs), rule: production.rhs.map { symbol in
            switch symbol {
            case .terminal(let name, _): .terminal(Terminal(string: name))
            case .nonterminal(let name): .nonTerminal(NonTerminal(name: name))
            }
        })
    }, start: NonTerminal(name: artifact.startSymbol), lexicalTokens: [:])
}

private func projectLRTrace(_ event: LRParserTraceEvent) -> LRTraceEvent? {
    let action: LRTraceAction
    switch event.kind {
    case .shift: action = .shift
    case .reduce: action = .reduce
    case .accept: action = .accept
    case .error, .recovery: action = .error
    case .start, .inspect: return nil
    }
    return LRTraceEvent(id: event.step, action: action, tokenIndex: event.tokenIndex,
        state: event.state.index, detail: event.description, stackDepth: event.stack.count)
}

private func projectTree(_ tree: Parser.ParseTree, source: String,
                         tokens: [PL0Token]) -> SyntaxNode? {
    switch tree {
    case .empty:
        return nil
    case .leaf(let range):
        let span = sourceRange(range, in: source)
        let kind = tokens.first { $0.range == span }?.kind.rawValue ?? "Token"
        return SyntaxNode(kind: kind, range: span)
    case .node(let nonterminal, let children):
        let projected = children.compactMap {
            projectTree($0, source: source, tokens: tokens)
        }
        return SyntaxNode(kind: nonterminal.name,
                          range: nodeRange(projected), children: projected)
    }
}

private func projectForest(_ snapshot: Parser.ParseForestSnapshot,
                           tokens: [PL0Token]) -> EarleyParseForest? {
    let edges = Dictionary(grouping: snapshot.edges, by: \.parent)
    var nodes: [String: EarleyForestNode] = [:]
    for node in snapshot.nodes {
        let lower = max(0, min(node.leftExtent, tokens.count))
        let upper = max(lower, min(node.rightExtent, tokens.count))
        let children = edges[node.id, default: []].map(\.child).sorted()
        let label = node.label ?? node.productionID?.rawValue ?? node.kind.rawValue
        nodes[node.id] = EarleyForestNode(id: node.id, symbol: label,
            tokenRange: lower..<upper, sourceRange: tokenSourceRange(lower..<upper, tokens: tokens),
            terminal: node.kind == .token ? tokenKind(grammarName: label) : nil,
            alternatives: children.isEmpty ? [] : [EarleyPackedAlternative(children: children)])
    }
    let rootID = snapshot.roots.first { nodes[$0]?.symbol == "Program" } ?? snapshot.roots.first
    guard let rootID, nodes[rootID] != nil else { return nil }
    return EarleyParseForest(rootID: rootID, nodes: nodes)
}

private func projectEarleyTrace(_ snapshot: Parser.ParseForestSnapshot?,
                                accepted: Bool) -> [EarleyTraceEvent] {
    guard let snapshot else { return [] }
    var trace = snapshot.nodes.enumerated().map { index, node in
        let action: EarleyTraceAction = switch node.kind {
        case .token: .scan
        case .symbol: .predict
        case .intermediate, .packed: .complete
        }
        return EarleyTraceEvent(id: index, action: action, chartIndex: node.rightExtent,
            production: node.label ?? node.productionID?.rawValue ?? node.kind.rawValue,
            dot: node.position ?? 0, origin: node.leftExtent)
    }
    if accepted {
        trace.append(EarleyTraceEvent(id: trace.count, action: .accept,
            chartIndex: snapshot.nodes.map(\.rightExtent).max() ?? 0,
            production: "Program", dot: 0, origin: 0))
    }
    return trace
}

private func reconstructedSource(_ tokens: [PL0Token]) -> String {
    var units = Array(repeating: UInt16(32), count: tokens.map(\.range.end).max() ?? 0)
    for token in tokens {
        let lexeme = Array(token.lexeme.utf16)
        guard token.range.location + lexeme.count <= units.count else { continue }
        units.replaceSubrange(token.range.location..<(token.range.location + lexeme.count), with: lexeme)
    }
    return String(decoding: units, as: UTF16.self)
}
private func sourceRange(_ range: Range<String.Index>, in source: String) -> SourceRange {
    let lower = range.lowerBound.utf16Offset(in: source)
    let upper = range.upperBound.utf16Offset(in: source)
    return SourceRange(location: lower, length: max(0, upper - lower))
}
private func nodeRange(_ children: [SyntaxNode]) -> SourceRange {
    guard let first = children.first, let last = children.last else { return SourceRange(location: 0, length: 0) }
    return SourceRange(location: first.range.location, length: max(0, last.range.end - first.range.location))
}
private func tokenSourceRange(_ range: Range<Int>, tokens: [PL0Token]) -> SourceRange {
    guard !range.isEmpty, range.lowerBound < tokens.count else {
        let offset = range.lowerBound < tokens.count ? tokens[range.lowerBound].range.location : tokens.last?.range.end ?? 0
        return SourceRange(location: offset, length: 0)
    }
    let first = tokens[range.lowerBound].range.location
    let last = tokens[min(range.upperBound - 1, tokens.count - 1)].range.end
    return SourceRange(location: first, length: max(0, last - first))
}
private func tokenKind(grammarName: String) -> PL0TokenKind? {
    PL0TokenKind.allCases.first { $0.grammarName == grammarName }
}
private func commonPrefix(_ lhs: [String], _ rhs: [String]) -> Int {
    var count = 0
    while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] { count += 1 }
    return count
}
private func reidentified(_ trace: [LRTraceEvent]) -> [LRTraceEvent] {
    trace.enumerated().map { index, event in LRTraceEvent(id: index + 1,
        action: event.action, tokenIndex: event.tokenIndex, state: event.state,
        detail: event.detail, stackDepth: event.stackDepth) }
}
private func reidentified(_ trace: [EarleyTraceEvent]) -> [EarleyTraceEvent] {
    trace.enumerated().map { index, event in EarleyTraceEvent(id: index + 1,
        action: event.action, chartIndex: event.chartIndex, production: event.production,
        dot: event.dot, origin: event.origin) }
}
