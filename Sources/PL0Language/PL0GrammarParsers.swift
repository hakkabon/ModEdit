import Foundation

/// Measurements from a grammar recognizer. Keeping these separate from the
/// normalized CST makes LR and Earley experiments directly comparable.
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
    /// IDs of terminal or nonterminal forest nodes in grammar order.
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

/// Generated SLR(1) parser for the controlled PL/0 grammar.
public struct LRPL0Parser: PL0ParserProtocol {
    public let descriptor = ParserDescriptor(
        id: "slr-1", displayName: "Generated SLR(1)",
        capabilities: [.deterministicTree, .errorRecovery, .expectedTokens, .incremental])

    public init() {}

    public func recognize(_ input: ParserInput) -> GrammarRecognition {
        parseDetailed(input).recognition
    }

    public func parseDetailed(_ input: ParserInput) -> LRParseArtifact {
        LRMachine.run(input.tokens).artifact
    }

    public func parse(_ input: ParserInput) -> ParserOutput {
        let detailed = parseDetailed(input)
        return output(for: detailed, input: input)
    }

    func output(for detailed: LRParseArtifact, input: ParserInput) -> ParserOutput {
        guard detailed.recognition.accepted, let root = detailed.root,
              input.lexicalDiagnostics.isEmpty else {
            return ReferencePL0Parser().parse(input)
        }
        let tree = ConcreteSyntaxTree(root: root, sourceTokens: input.tokens)
        return ParserOutput(syntaxTree: tree, diagnostics: [],
                            recovery: RecoveryModel(actions: [], expectations: [], diagnostics: []))
    }
}

/// Chart-based Earley recognizer. It accepts the same grammar without relying
/// on LR conflict properties and is the foundation for later ambiguity and
/// error-recovery experiments.
public struct EarleyPL0Parser: PL0ParserProtocol {
    public let descriptor = ParserDescriptor(
        id: "earley", displayName: "Earley Chart",
        capabilities: [.deterministicTree, .errorRecovery, .expectedTokens,
                       .incremental, .ambiguity])

    public init() {}

    public func recognize(_ input: ParserInput) -> GrammarRecognition {
        parseDetailed(input).recognition
    }

    public func parseDetailed(_ input: ParserInput) -> EarleyParseArtifact {
        EarleyMachine.run(input.tokens).artifact
    }

    public func parse(_ input: ParserInput) -> ParserOutput {
        let detailed = parseDetailed(input)
        return output(for: detailed, input: input)
    }

    func output(for detailed: EarleyParseArtifact, input: ParserInput) -> ParserOutput {
        guard detailed.recognition.accepted, let forest = detailed.forest,
              let root = forest.syntaxTreeRoot(), input.lexicalDiagnostics.isEmpty else {
            return ReferencePL0Parser().parse(input)
        }
        let tree = ConcreteSyntaxTree(root: root, sourceTokens: input.tokens)
        return ParserOutput(syntaxTree: tree, diagnostics: [],
                            recovery: RecoveryModel(actions: [], expectations: [], diagnostics: []))
    }
}

/// Stateful LR driver. Stable token identities supplied by the incremental
/// lexer determine the maximal safe checkpoint from which parsing resumes.
public struct IncrementalLRPL0Parser: Sendable {
    private var cache: LRCache?
    public init() {}
    public mutating func parse(_ input: ParserInput) -> LRParseArtifact {
        let run = LRMachine.run(input.tokens, previous: cache)
        cache = run.cache
        return run.artifact
    }
    public mutating func reset() { cache = nil }
}

/// Stateful Earley driver. Closed chart columns before the first changed token
/// are immutable and can be reused without prediction/completion work.
public struct IncrementalEarleyPL0Parser: Sendable {
    private var cache: EarleyCache?
    public init() {}
    public mutating func parse(_ input: ParserInput) -> EarleyParseArtifact {
        let run = EarleyMachine.run(input.tokens, previous: cache)
        cache = run.cache
        return run.artifact
    }
    public mutating func reset() { cache = nil }
}

private enum GrammarSymbol: Hashable, Sendable {
    case terminal(PL0TokenKind)
    case nonterminal(String)
}

private struct GrammarProduction: Hashable, Sendable {
    let lhs: String
    let rhs: [GrammarSymbol]
}

private struct PL0Grammar: Sendable {
    let start = "Program"
    let productions: [GrammarProduction]
    let byLHS: [String: [Int]]

    init() {
        typealias S = GrammarSymbol
        func t(_ kind: PL0TokenKind) -> S { .terminal(kind) }
        func n(_ name: String) -> S { .nonterminal(name) }
        let p: [GrammarProduction] = [
            .init(lhs: "Program", rhs: [n("Block"), t(.period)]),
            .init(lhs: "Block", rhs: [n("ConstPart"), n("VarPart"), n("Procedures"), n("Statement")]),
            .init(lhs: "ConstPart", rhs: [t(.const), n("ConstDefinition"), n("MoreConsts"), t(.semicolon)]),
            .init(lhs: "ConstPart", rhs: []),
            .init(lhs: "ConstDefinition", rhs: [t(.identifier), t(.equal), t(.number)]),
            .init(lhs: "MoreConsts", rhs: [t(.comma), n("ConstDefinition"), n("MoreConsts")]),
            .init(lhs: "MoreConsts", rhs: []),
            .init(lhs: "VarPart", rhs: [t(.varKeyword), t(.identifier), n("MoreVars"), t(.semicolon)]),
            .init(lhs: "VarPart", rhs: []),
            .init(lhs: "MoreVars", rhs: [t(.comma), t(.identifier), n("MoreVars")]),
            .init(lhs: "MoreVars", rhs: []),
            .init(lhs: "Procedures", rhs: [t(.procedure), t(.identifier), t(.semicolon), n("Block"), t(.semicolon), n("Procedures")]),
            .init(lhs: "Procedures", rhs: []),
            .init(lhs: "Statement", rhs: [t(.identifier), t(.assign), n("Expression")]),
            .init(lhs: "Statement", rhs: [t(.call), t(.identifier)]),
            .init(lhs: "Statement", rhs: [t(.begin), n("Statement"), n("MoreStatements"), t(.end)]),
            .init(lhs: "Statement", rhs: [t(.ifKeyword), n("Condition"), t(.then), n("Statement")]),
            .init(lhs: "Statement", rhs: [t(.whileKeyword), n("Condition"), t(.doKeyword), n("Statement")]),
            .init(lhs: "Statement", rhs: []),
            .init(lhs: "MoreStatements", rhs: [t(.semicolon), n("Statement"), n("MoreStatements")]),
            .init(lhs: "MoreStatements", rhs: []),
            .init(lhs: "Condition", rhs: [t(.odd), n("Expression")]),
            .init(lhs: "Condition", rhs: [n("Expression"), n("Relation"), n("Expression")]),
            .init(lhs: "Relation", rhs: [t(.equal)]),
            .init(lhs: "Relation", rhs: [t(.notEqual)]),
            .init(lhs: "Relation", rhs: [t(.less)]),
            .init(lhs: "Relation", rhs: [t(.lessEqual)]),
            .init(lhs: "Relation", rhs: [t(.greater)]),
            .init(lhs: "Relation", rhs: [t(.greaterEqual)]),
            .init(lhs: "Expression", rhs: [n("Sign"), n("Term"), n("MoreTerms")]),
            .init(lhs: "Sign", rhs: [t(.plus)]),
            .init(lhs: "Sign", rhs: [t(.minus)]),
            .init(lhs: "Sign", rhs: []),
            .init(lhs: "MoreTerms", rhs: [t(.plus), n("Term"), n("MoreTerms")]),
            .init(lhs: "MoreTerms", rhs: [t(.minus), n("Term"), n("MoreTerms")]),
            .init(lhs: "MoreTerms", rhs: []),
            .init(lhs: "Term", rhs: [n("Factor"), n("MoreFactors")]),
            .init(lhs: "MoreFactors", rhs: [t(.star), n("Factor"), n("MoreFactors")]),
            .init(lhs: "MoreFactors", rhs: [t(.slash), n("Factor"), n("MoreFactors")]),
            .init(lhs: "MoreFactors", rhs: []),
            .init(lhs: "Factor", rhs: [t(.identifier)]),
            .init(lhs: "Factor", rhs: [t(.number)]),
            .init(lhs: "Factor", rhs: [t(.leftParen), n("Expression"), t(.rightParen)]),
        ]
        productions = p
        byLHS = Dictionary(grouping: p.indices, by: { p[$0].lhs })
    }

    static let shared = PL0Grammar()
}

private struct LRItem: Hashable { let production: Int; let dot: Int }
private enum LRAction: Equatable { case shift(Int), reduce(Int), accept }
private struct ActionKey: Hashable { let state: Int; let terminal: PL0TokenKind }
private struct GotoKey: Hashable { let state: Int; let nonterminal: String }

private struct SLRTable {
    let productions: [GrammarProduction]
    let actions: [ActionKey: LRAction]
    let gotos: [GotoKey: Int]
    let stateCount: Int

    init(grammar: PL0Grammar) {
        let augmented = GrammarProduction(lhs: "$Start", rhs: [.nonterminal(grammar.start)])
        let allProductions = [augmented] + grammar.productions
        let indicesByLHS = Dictionary(grouping: allProductions.indices,
                                      by: { allProductions[$0].lhs })

        func closure(_ seed: Set<LRItem>) -> Set<LRItem> {
            var result = seed
            var changed = true
            while changed {
                changed = false
                for item in result {
                    let production = allProductions[item.production]
                    guard item.dot < production.rhs.count,
                          case let .nonterminal(name) = production.rhs[item.dot] else { continue }
                    for productionIndex in indicesByLHS[name, default: []] {
                        changed = result.insert(LRItem(production: productionIndex, dot: 0)).inserted || changed
                    }
                }
            }
            return result
        }

        func moved(_ state: Set<LRItem>, over symbol: GrammarSymbol) -> Set<LRItem> {
            closure(Set(state.compactMap { item in
                let production = allProductions[item.production]
                guard item.dot < production.rhs.count,
                      production.rhs[item.dot] == symbol else { return nil }
                return LRItem(production: item.production, dot: item.dot + 1)
            }))
        }

        var states = [closure([LRItem(production: 0, dot: 0)])]
        var transitions: [Int: [GrammarSymbol: Int]] = [:]
        var cursor = 0
        while cursor < states.count {
            let symbols = Set(states[cursor].compactMap { item -> GrammarSymbol? in
                let p = allProductions[item.production]
                return item.dot < p.rhs.count ? p.rhs[item.dot] : nil
            })
            for symbol in symbols {
                let target = moved(states[cursor], over: symbol)
                let destination: Int
                if let existing = states.firstIndex(of: target) { destination = existing }
                else { destination = states.count; states.append(target) }
                transitions[cursor, default: [:]][symbol] = destination
            }
            cursor += 1
        }

        let follow = SLRTable.followSets(productions: allProductions)
        var actionTable: [ActionKey: LRAction] = [:]
        var gotoTable: [GotoKey: Int] = [:]
        for state in states.indices {
            for (symbol, destination) in transitions[state, default: [:]] {
                switch symbol {
                case let .terminal(kind): actionTable[ActionKey(state: state, terminal: kind)] = .shift(destination)
                case let .nonterminal(name): gotoTable[GotoKey(state: state, nonterminal: name)] = destination
                }
            }
            for item in states[state] where item.dot == allProductions[item.production].rhs.count {
                if item.production == 0 {
                    actionTable[ActionKey(state: state, terminal: .endOfFile)] = .accept
                } else {
                    for terminal in follow[allProductions[item.production].lhs, default: []] {
                        let key = ActionKey(state: state, terminal: terminal)
                        // Shift wins the classic optional-statement boundary;
                        // otherwise identical reductions are harmless.
                        if case .shift = actionTable[key] { continue }
                        actionTable[key] = .reduce(item.production)
                    }
                }
            }
        }
        productions = allProductions
        actions = actionTable
        gotos = gotoTable
        stateCount = states.count
    }

    private static func followSets(productions: [GrammarProduction]) -> [String: Set<PL0TokenKind>] {
        let nonterminals = Set(productions.map(\.lhs))
        var first: [String: Set<PL0TokenKind>] = [:]
        var nullable = Set<String>()
        var changed = true
        while changed {
            changed = false
            for production in productions {
                if production.rhs.isEmpty {
                    changed = nullable.insert(production.lhs).inserted || changed
                    continue
                }
                var allNullable = true
                for symbol in production.rhs {
                    switch symbol {
                    case let .terminal(kind):
                        changed = first[production.lhs, default: []].insert(kind).inserted || changed
                        allNullable = false
                    case let .nonterminal(name):
                        let before = first[production.lhs, default: []].count
                        first[production.lhs, default: []].formUnion(first[name, default: []])
                        changed = first[production.lhs, default: []].count != before || changed
                        if !nullable.contains(name) { allNullable = false }
                    }
                    if !allNullable { break }
                }
                if allNullable { changed = nullable.insert(production.lhs).inserted || changed }
            }
        }
        var follow: [String: Set<PL0TokenKind>] = ["$Start": [.endOfFile]]
        changed = true
        while changed {
            changed = false
            for production in productions {
                for position in production.rhs.indices {
                    guard case let .nonterminal(name) = production.rhs[position] else { continue }
                    var suffixNullable = true
                    for symbol in production.rhs[(position + 1)...] {
                        switch symbol {
                        case let .terminal(kind):
                            changed = follow[name, default: []].insert(kind).inserted || changed
                            suffixNullable = false
                        case let .nonterminal(next):
                            let before = follow[name, default: []].count
                            follow[name, default: []].formUnion(first[next, default: []])
                            changed = follow[name, default: []].count != before || changed
                            if !nullable.contains(next) { suffixNullable = false }
                        }
                        if !suffixNullable { break }
                    }
                    if suffixNullable {
                        let before = follow[name, default: []].count
                        follow[name, default: []].formUnion(follow[production.lhs, default: []])
                        changed = follow[name, default: []].count != before || changed
                    }
                }
            }
        }
        _ = nonterminals // documents that FIRST only tracks grammar nonterminals
        return follow
    }
}

private struct LRCheckpoint: Sendable {
    let states: [Int]
    let nodes: [SyntaxNode]
}

private struct LRCache: Sendable {
    let tokenIDs: [String]
    let checkpoints: [LRCheckpoint]
}

private struct LRRun {
    let artifact: LRParseArtifact
    let cache: LRCache
}

private enum LRMachine {
    static let table = SLRTable(grammar: .shared)

    static func run(_ sourceTokens: [PL0Token], previous: LRCache? = nil) -> LRRun {
        let tokens = normalizedTokens(sourceTokens)
        let ids = tokens.dropLast().map(\.id)
        let reusable = previous.map { commonPrefix(ids, $0.tokenIDs) } ?? 0
        let checkpoint = previous.flatMap { reusable < $0.checkpoints.count ? $0.checkpoints[reusable] : nil }
        var states = checkpoint?.states ?? [0]
        var nodes = checkpoint?.nodes ?? []
        var cursor = checkpoint == nil ? 0 : reusable
        var checkpoints = checkpoint == nil
            ? [LRCheckpoint(states: states, nodes: nodes)]
            : Array(previous!.checkpoints.prefix(reusable + 1))
        var trace: [LRTraceEvent] = []
        if reusable > 0 {
            trace.append(LRTraceEvent(id: 0, action: .reuse, tokenIndex: reusable,
                                      state: states.last ?? 0,
                                      detail: "resume after \(reusable) stable tokens",
                                      stackDepth: states.count))
        }
        var configurations = 0
        var maximumDepth = states.count
        let limit = max(1_000, tokens.count * 20)

        func event(_ action: LRTraceAction, _ detail: String) -> LRTraceEvent {
            LRTraceEvent(id: trace.count, action: action, tokenIndex: cursor,
                         state: states.last ?? 0, detail: detail,
                         stackDepth: states.count)
        }

        while configurations < limit {
            configurations += 1
            let lookahead = tokens[min(cursor, tokens.count - 1)]
            guard let action = table.actions[ActionKey(state: states.last!,
                                                       terminal: lookahead.kind)] else {
                trace.append(event(.error, "no action for \(lookahead.kind.displayName)"))
                return finish(false)
            }
            switch action {
            case let .shift(state):
                trace.append(event(.shift, "\(lookahead.kind.rawValue) → state \(state)"))
                states.append(state)
                nodes.append(SyntaxNode(kind: lookahead.kind.rawValue,
                                        range: lookahead.range))
                cursor += 1
                maximumDepth = max(maximumDepth, states.count)
                if cursor <= ids.count {
                    checkpoints.append(LRCheckpoint(states: states, nodes: nodes))
                }
            case let .reduce(productionIndex):
                let production = table.productions[productionIndex]
                let count = production.rhs.count
                guard count < states.count, count <= nodes.count else {
                    trace.append(event(.error, "invalid reduction stack"))
                    return finish(false)
                }
                let children = count == 0 ? [] : Array(nodes.suffix(count))
                if count > 0 {
                    states.removeLast(count)
                    nodes.removeLast(count)
                }
                guard let state = table.gotos[GotoKey(state: states.last!,
                                                      nonterminal: production.lhs)] else {
                    trace.append(event(.error, "missing goto for \(production.lhs)"))
                    return finish(false)
                }
                let emptyOffset = lookahead.range.location
                let range = nodeRange(children, emptyAt: emptyOffset)
                nodes.append(SyntaxNode(kind: production.lhs, range: range,
                                        children: children))
                states.append(state)
                trace.append(event(.reduce,
                                   "r\(productionIndex): \(productionText(production)) → state \(state)"))
                maximumDepth = max(maximumDepth, states.count)
            case .accept:
                trace.append(event(.accept, "accept"))
                return finish(true)
            }
        }
        trace.append(event(.error, "configuration limit exceeded"))
        return finish(false)

        func finish(_ accepted: Bool) -> LRRun {
            let recognition = GrammarRecognition(
                accepted: accepted, consumedTokenCount: min(cursor, ids.count),
                configurationCount: configurations,
                maximumFrontierSize: maximumDepth)
            return LRRun(
                artifact: LRParseArtifact(recognition: recognition,
                                          root: accepted ? nodes.last : nil,
                                          trace: trace,
                                          reusedTokenCount: reusable),
                cache: LRCache(tokenIDs: ids, checkpoints: checkpoints))
        }
    }
}

private struct EarleyItem: Hashable, Sendable {
    let production: Int
    let dot: Int
    let origin: Int
}

private struct MutableForestNode: Sendable {
    let id: String
    let symbol: String
    let start: Int
    let end: Int
    let terminal: PL0TokenKind?
    var alternatives: Set<EarleyPackedAlternative>
}

private struct EarleyCache: Sendable {
    let tokenIDs: [String]
    let chart: [Set<EarleyItem>]
    let families: [Int: [EarleyItem: Set<[String]>]]
    let forest: [String: MutableForestNode]
}

private struct EarleyRun {
    let artifact: EarleyParseArtifact
    let cache: EarleyCache
}

private enum EarleyMachine {
    static func run(_ sourceTokens: [PL0Token], previous: EarleyCache? = nil) -> EarleyRun {
        let grammar = PL0Grammar.shared
        let augmented = GrammarProduction(lhs: "$Start", rhs: [.nonterminal(grammar.start)])
        let productions = [augmented] + grammar.productions
        let byLHS = Dictionary(grouping: productions.indices, by: { productions[$0].lhs })
        let tokens = Array(normalizedTokens(sourceTokens).dropLast())
        let ids = tokens.map(\.id)
        let reusable = min(tokens.count,
                           previous.map { commonPrefix(ids, $0.tokenIDs) } ?? 0)
        var chart: [Set<EarleyItem>]
        var families: [Int: [EarleyItem: Set<[String]>]]
        var forest: [String: MutableForestNode]
        if let previous, reusable > 0 {
            chart = Array(previous.chart.prefix(reusable + 1))
            chart += Array(repeating: [], count: tokens.count + 1 - chart.count)
            families = previous.families.filter { $0.key <= reusable }
            forest = previous.forest.filter { $0.value.end <= reusable }
        } else {
            chart = Array(repeating: [], count: tokens.count + 1)
            families = [:]
            forest = [:]
            let start = EarleyItem(production: 0, dot: 0, origin: 0)
            chart[0].insert(start)
            families[0, default: [:]][start] = [[]]
        }
        var trace: [EarleyTraceEvent] = []
        if reusable > 0 {
            trace.append(EarleyTraceEvent(id: 0, action: .reuse,
                                          chartIndex: reusable,
                                          production: "reuse \(reusable) closed columns",
                                          dot: 0, origin: 0))
        }
        var configurations = 0
        var maximum = chart.prefix(reusable + 1).map(\.count).max() ?? 1

        func add(_ item: EarleyItem, at position: Int, family: [String],
                 to agenda: inout [EarleyItem]) -> Bool {
            let newItem = chart[position].insert(item).inserted
            let newFamily = families[position, default: [:]][item, default: []]
                .insert(family).inserted
            if newItem || newFamily { agenda.append(item) }
            return newItem || newFamily
        }

        let startPosition = reusable > 0 ? reusable : 0
        for position in startPosition..<chart.count {
            var agenda = Array(chart[position])
            var agendaCursor = 0
            while agendaCursor < agenda.count {
                let item = agenda[agendaCursor]
                agendaCursor += 1
                configurations += 1
                let production = productions[item.production]
                let itemFamilies = families[position]?[item] ?? [[]]
                if item.dot < production.rhs.count {
                    switch production.rhs[item.dot] {
                    case let .nonterminal(name):
                        for productionIndex in byLHS[name, default: []] {
                            let predicted = EarleyItem(production: productionIndex,
                                                       dot: 0, origin: position)
                            if add(predicted, at: position, family: [], to: &agenda) {
                                trace.append(traceEvent(.predict, position, predicted,
                                                        productions, trace.count))
                            }
                        }
                    case let .terminal(kind):
                        guard position < tokens.count, tokens[position].kind == kind else { break }
                        let terminalID = "t:\(position):\(kind.rawValue)"
                        forest[terminalID] = MutableForestNode(
                            id: terminalID, symbol: kind.rawValue,
                            start: position, end: position + 1, terminal: kind,
                            alternatives: [])
                        let advanced = EarleyItem(production: item.production,
                                                  dot: item.dot + 1,
                                                  origin: item.origin)
                        for family in itemFamilies {
                            var next = family; next.append(terminalID)
                            var unused: [EarleyItem] = []
                            if add(advanced, at: position + 1, family: next,
                                   to: &unused) {
                                trace.append(traceEvent(.scan, position + 1, advanced,
                                                        productions, trace.count))
                            }
                        }
                    }
                } else {
                    let nodeID = "n:\(production.lhs):\(item.origin):\(position)"
                    var packed = forest[nodeID] ?? MutableForestNode(
                        id: nodeID, symbol: production.lhs,
                        start: item.origin, end: position, terminal: nil,
                        alternatives: [])
                    var changed = false
                    for family in itemFamilies {
                        changed = packed.alternatives.insert(
                            EarleyPackedAlternative(children: family)).inserted || changed
                    }
                    forest[nodeID] = packed
                    if changed {
                        trace.append(traceEvent(.complete, position, item,
                                                productions, trace.count))
                    }
                    for waiting in chart[item.origin] {
                        let waitingProduction = productions[waiting.production]
                        guard waiting.dot < waitingProduction.rhs.count,
                              waitingProduction.rhs[waiting.dot] == .nonterminal(production.lhs) else { continue }
                        let advanced = EarleyItem(production: waiting.production,
                                                  dot: waiting.dot + 1,
                                                  origin: waiting.origin)
                        for family in families[item.origin]?[waiting] ?? [[]] {
                            var next = family; next.append(nodeID)
                            _ = add(advanced, at: position, family: next, to: &agenda)
                        }
                    }
                }
            }
            maximum = max(maximum, chart[position].count)
        }
        let acceptedItem = EarleyItem(production: 0, dot: 1, origin: 0)
        let accepted = chart[tokens.count].contains(acceptedItem)
        let rootID = "n:Program:0:\(tokens.count)"
        let publicNodes = forest.mapValues { node in
            EarleyForestNode(id: node.id, symbol: node.symbol,
                             tokenRange: node.start..<node.end,
                             sourceRange: sourceRange(node.start..<node.end, tokens: tokens),
                             terminal: node.terminal,
                             alternatives: node.alternatives.sorted {
                                 $0.children.lexicographicallyPrecedes($1.children)
                             })
        }
        let parseForest = accepted && publicNodes[rootID] != nil
            ? EarleyParseForest(rootID: rootID, nodes: publicNodes) : nil
        if accepted {
            trace.append(EarleyTraceEvent(id: trace.count, action: .accept,
                                          chartIndex: tokens.count,
                                          production: "$Start → Program", dot: 1,
                                          origin: 0))
        }
        let consumed = chart.lastIndex(where: { !$0.isEmpty }) ?? 0
        let recognition = GrammarRecognition(
            accepted: accepted, consumedTokenCount: consumed,
            configurationCount: configurations,
            maximumFrontierSize: maximum)
        return EarleyRun(
            artifact: EarleyParseArtifact(recognition: recognition,
                                          forest: parseForest, trace: trace,
                                          reusedChartColumnCount: reusable),
            cache: EarleyCache(tokenIDs: ids, chart: chart,
                               families: families, forest: forest))
    }
}

private extension EarleyParseForest {
    func syntaxTreeRoot() -> SyntaxNode? {
        var visiting = Set<String>()
        func build(_ id: String) -> SyntaxNode? {
            guard let node = nodes[id], visiting.insert(id).inserted else { return nil }
            defer { visiting.remove(id) }
            if node.terminal != nil {
                return SyntaxNode(kind: node.symbol, range: node.sourceRange)
            }
            let children = node.alternatives.first?.children.compactMap(build) ?? []
            return SyntaxNode(kind: node.symbol, range: node.sourceRange,
                              children: children)
        }
        return build(rootID)
    }
}

private func traceEvent(_ action: EarleyTraceAction, _ chartIndex: Int,
                        _ item: EarleyItem, _ productions: [GrammarProduction],
                        _ id: Int) -> EarleyTraceEvent {
    EarleyTraceEvent(id: id, action: action, chartIndex: chartIndex,
                     production: productionText(productions[item.production]),
                     dot: item.dot, origin: item.origin)
}

private func productionText(_ production: GrammarProduction) -> String {
    let rhs = production.rhs.map { symbol in
        switch symbol {
        case let .terminal(kind): kind.rawValue
        case let .nonterminal(name): name
        }
    }.joined(separator: " ")
    return "\(production.lhs) → \(rhs.isEmpty ? "ε" : rhs)"
}

private func nodeRange(_ children: [SyntaxNode], emptyAt offset: Int) -> SourceRange {
    guard let first = children.first, let last = children.last else {
        return SourceRange(location: offset, length: 0)
    }
    return SourceRange(location: first.range.location,
                       length: max(0, last.range.end - first.range.location))
}

private func sourceRange(_ tokenRange: Range<Int>, tokens: [PL0Token]) -> SourceRange {
    guard !tokenRange.isEmpty, tokenRange.lowerBound < tokens.count else {
        let offset = tokenRange.lowerBound < tokens.count
            ? tokens[tokenRange.lowerBound].range.location
            : tokens.last?.range.end ?? 0
        return SourceRange(location: offset, length: 0)
    }
    let first = tokens[tokenRange.lowerBound].range.location
    let last = tokens[min(tokenRange.upperBound - 1, tokens.count - 1)].range.end
    return SourceRange(location: first, length: max(0, last - first))
}

private func commonPrefix(_ lhs: [String], _ rhs: [String]) -> Int {
    var count = 0
    while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] { count += 1 }
    return count
}

private func normalizedTokens(_ tokens: [PL0Token]) -> [PL0Token] {
    guard tokens.last?.kind != .endOfFile else { return tokens }
    let last = tokens.last
    let offset = last?.range.end ?? 0
    return tokens + [PL0Token(id: "grammar:eof:\(offset)", kind: .endOfFile,
                             lexeme: "", range: SourceRange(location: offset, length: 0),
                             location: SourceLocation(offset: offset,
                                                      line: last?.location.line ?? 1,
                                                      column: last?.location.column ?? 1))]
}

private func normalizedKinds(_ tokens: [PL0Token]) -> [PL0TokenKind] {
    var kinds = tokens.map(\.kind)
    if kinds.last != .endOfFile { kinds.append(.endOfFile) }
    return kinds
}
