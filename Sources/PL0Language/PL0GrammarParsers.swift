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

/// Generated SLR(1) recognizer for the controlled PL/0 grammar. The existing
/// reference parser remains the CST/recovery normalizer so every engine emits
/// exactly the same parser-neutral model while recognition is independent.
public struct LRPL0Parser: PL0ParserProtocol {
    public let descriptor = ParserDescriptor(
        id: "slr-1", displayName: "Generated SLR(1)",
        capabilities: [.deterministicTree, .expectedTokens])

    public init() {}

    public func recognize(_ input: ParserInput) -> GrammarRecognition {
        PL0SLRRecognizer.recognize(input.tokens)
    }

    public func parse(_ input: ParserInput) -> ParserOutput {
        // CST construction and recovery are deliberately normalized through
        // one adapter until LR reductions grow their own tree builder.
        ReferencePL0Parser().parse(input)
    }
}

/// Chart-based Earley recognizer. It accepts the same grammar without relying
/// on LR conflict properties and is the foundation for later ambiguity and
/// error-recovery experiments.
public struct EarleyPL0Parser: PL0ParserProtocol {
    public let descriptor = ParserDescriptor(
        id: "earley", displayName: "Earley Chart",
        capabilities: [.deterministicTree, .errorRecovery, .expectedTokens, .ambiguity])

    public init() {}

    public func recognize(_ input: ParserInput) -> GrammarRecognition {
        PL0EarleyRecognizer.recognize(input.tokens)
    }

    public func parse(_ input: ParserInput) -> ParserOutput {
        ReferencePL0Parser().parse(input)
    }
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

private enum PL0SLRRecognizer {
    static let table = SLRTable(grammar: .shared)

    static func recognize(_ sourceTokens: [PL0Token]) -> GrammarRecognition {
        let tokens = normalizedKinds(sourceTokens)
        var stack = [0]
        var cursor = 0
        var configurations = 0
        var maximumDepth = 1
        while configurations < max(1_000, tokens.count * 20) {
            configurations += 1
            let lookahead = tokens[min(cursor, tokens.count - 1)]
            guard let action = table.actions[ActionKey(state: stack.last!, terminal: lookahead)] else {
                return GrammarRecognition(accepted: false, consumedTokenCount: cursor,
                                          configurationCount: configurations,
                                          maximumFrontierSize: maximumDepth)
            }
            switch action {
            case let .shift(state):
                stack.append(state); cursor += 1; maximumDepth = max(maximumDepth, stack.count)
            case let .reduce(productionIndex):
                let production = table.productions[productionIndex]
                if production.rhs.count >= stack.count {
                    return GrammarRecognition(accepted: false, consumedTokenCount: cursor,
                                              configurationCount: configurations,
                                              maximumFrontierSize: maximumDepth)
                }
                stack.removeLast(production.rhs.count)
                guard let state = table.gotos[GotoKey(state: stack.last!, nonterminal: production.lhs)] else {
                    return GrammarRecognition(accepted: false, consumedTokenCount: cursor,
                                              configurationCount: configurations,
                                              maximumFrontierSize: maximumDepth)
                }
                stack.append(state); maximumDepth = max(maximumDepth, stack.count)
            case .accept:
                return GrammarRecognition(accepted: true, consumedTokenCount: cursor,
                                          configurationCount: configurations,
                                          maximumFrontierSize: maximumDepth)
            }
        }
        return GrammarRecognition(accepted: false, consumedTokenCount: cursor,
                                  configurationCount: configurations,
                                  maximumFrontierSize: maximumDepth)
    }
}

private struct EarleyItem: Hashable { let production: Int; let dot: Int; let origin: Int }
private enum PL0EarleyRecognizer {
    static func recognize(_ sourceTokens: [PL0Token]) -> GrammarRecognition {
        let grammar = PL0Grammar.shared
        let augmented = GrammarProduction(lhs: "$Start", rhs: [.nonterminal(grammar.start)])
        let productions = [augmented] + grammar.productions
        let byLHS = Dictionary(grouping: productions.indices, by: { productions[$0].lhs })
        let input = normalizedKinds(sourceTokens).dropLast()
        var chart = Array(repeating: Set<EarleyItem>(), count: input.count + 1)
        chart[0].insert(EarleyItem(production: 0, dot: 0, origin: 0))
        var configurations = 0
        var maximum = 1

        for position in chart.indices {
            var agenda = Array(chart[position])
            var cursor = 0
            while cursor < agenda.count {
                let item = agenda[cursor]; cursor += 1; configurations += 1
                let production = productions[item.production]
                if item.dot < production.rhs.count {
                    switch production.rhs[item.dot] {
                    case let .nonterminal(name):
                        for productionIndex in byLHS[name, default: []] {
                            let predicted = EarleyItem(production: productionIndex, dot: 0,
                                                       origin: position)
                            if chart[position].insert(predicted).inserted { agenda.append(predicted) }
                        }
                    case let .terminal(kind):
                        if position < input.count, input[input.index(input.startIndex, offsetBy: position)] == kind {
                            chart[position + 1].insert(EarleyItem(
                                production: item.production, dot: item.dot + 1,
                                origin: item.origin))
                        }
                    }
                } else {
                    for waiting in chart[item.origin] {
                        let waitingProduction = productions[waiting.production]
                        guard waiting.dot < waitingProduction.rhs.count,
                              waitingProduction.rhs[waiting.dot] == .nonterminal(production.lhs) else { continue }
                        let completed = EarleyItem(production: waiting.production,
                                                   dot: waiting.dot + 1,
                                                   origin: waiting.origin)
                        if chart[position].insert(completed).inserted { agenda.append(completed) }
                    }
                }
            }
            maximum = max(maximum, chart[position].count)
        }
        let accepted = chart[input.count].contains(EarleyItem(production: 0, dot: 1, origin: 0))
        let consumed = chart.lastIndex(where: { !$0.isEmpty }) ?? 0
        return GrammarRecognition(accepted: accepted, consumedTokenCount: consumed,
                                  configurationCount: configurations,
                                  maximumFrontierSize: maximum)
    }
}

private func normalizedKinds(_ tokens: [PL0Token]) -> [PL0TokenKind] {
    var kinds = tokens.map(\.kind)
    if kinds.last != .endOfFile { kinds.append(.endOfFile) }
    return kinds
}
