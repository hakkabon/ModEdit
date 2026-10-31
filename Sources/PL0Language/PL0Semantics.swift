import Foundation

public enum PL0SymbolKind: String, Sendable, Equatable, Codable {
    case constant, variable, procedure
}

public struct PL0Symbol: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: PL0SymbolKind
    public let declarationRange: SourceRange
    public let scopeID: Int
    public let lexicalLevel: Int
    public let slot: Int?
    public let constantValue: Int?
}

public struct PL0SymbolReference: Sendable, Equatable, Identifiable {
    public let range: SourceRange
    public let symbolID: String
    public var id: String { "\(range.location):\(range.length):\(symbolID)" }
}

public struct PL0SemanticScope: Sendable, Equatable, Identifiable {
    public let id: Int
    public let parentID: Int?
    public let range: SourceRange
    public let symbolIDs: [String]
}

public enum PL0SemanticClassification: Sendable, Equatable {
    case keyword
    case number
    case operatorToken
    case symbol(PL0SymbolKind)
}

public struct PL0SemanticToken: Sendable, Equatable, Identifiable {
    public let range: SourceRange
    public let classification: PL0SemanticClassification
    public let isDeclaration: Bool
    public var id: String { "\(range.location):\(range.length):\(isDeclaration)" }
}

/// Parser-independent semantic evidence for one exact prepared document.
/// Symbol IDs come from stable lexer token IDs, so unchanged declarations keep
/// their identity across incremental edits.
public struct PL0SemanticModel: Sendable {
    public let version: UInt64
    public let grammarFingerprint: String
    public let symbols: [PL0Symbol]
    public let references: [PL0SymbolReference]
    public let scopes: [PL0SemanticScope]
    public let semanticTokens: [PL0SemanticToken]
    public let diagnostics: [ParseDiagnostic]

    public func symbol(id: String) -> PL0Symbol? {
        symbols.first { $0.id == id }
    }

    public func declaration(referencedAt offset: Int) -> PL0Symbol? {
        guard let reference = references.first(where: {
            offset >= $0.range.location && offset <= $0.range.end
        }) else { return nil }
        return symbol(id: reference.symbolID)
    }

    public func visibleSymbols(at offset: Int) -> [PL0Symbol] {
        guard var scope = scopes.filter({
            offset >= $0.range.location && offset <= $0.range.end
        }).min(by: { $0.range.length < $1.range.length }) else { return [] }
        var result: [PL0Symbol] = []
        var names = Set<String>()
        while true {
            for id in scope.symbolIDs {
                guard let symbol = symbol(id: id) else { continue }
                if names.insert(symbol.name.lowercased()).inserted { result.append(symbol) }
            }
            guard let parent = scope.parentID,
                  let next = scopes.first(where: { $0.id == parent }) else { break }
            scope = next
        }
        return result
    }
}

public struct PL0Analysis: Sendable {
    public let prepared: PL0PreparedFrontend
    public let parse: ParseResult
    public let semantics: PL0SemanticModel
}

public struct PL0SemanticAnalyzer: Sendable {
    public init() {}

    public func analyze(_ prepared: PL0PreparedFrontend,
                        parse: ParseResult) -> PL0SemanticModel {
        precondition(parse.version == prepared.snapshot.version,
                     "Semantic input and parse revisions differ")
        precondition(parse.grammarArtifact.fingerprint == prepared.grammarFingerprint,
                     "Semantic input and parse grammars differ")
        return Analyzer(prepared: prepared).build()
    }
}

private final class Analyzer {
    private struct Scope {
        let id: Int
        let parentID: Int?
        let level: Int
        let start: Int
        var end: Int
        var symbols: [String: String] = [:]
        var symbolIDs: [String] = []
        var nextVariableSlot = 0
    }

    private let prepared: PL0PreparedFrontend
    private let tokens: [PL0Token]
    private var index = 0
    private var symbols: [String: PL0Symbol] = [:]
    private var references: [PL0SymbolReference] = []
    private var scopes: [Scope] = []
    private var scopeStack: [Int] = []
    private var semanticTokens: [PL0SemanticToken] = []
    private var diagnostics: [ParseDiagnostic] = []

    init(prepared: PL0PreparedFrontend) {
        self.prepared = prepared
        tokens = prepared.input.tokens
    }

    private var current: PL0Token { tokens[min(index, max(0, tokens.count - 1))] }

    func build() -> PL0SemanticModel {
        guard !tokens.isEmpty else { return emptyModel() }
        parseBlock(parent: nil)
        for token in tokens {
            if let classification = classification(token.kind) {
                semanticTokens.append(PL0SemanticToken(
                    range: token.range, classification: classification,
                    isDeclaration: false))
            }
        }
        semanticTokens.sort { $0.range.location < $1.range.location }
        return PL0SemanticModel(
            version: prepared.snapshot.version,
            grammarFingerprint: prepared.grammarFingerprint,
            symbols: symbols.values.sorted {
                $0.declarationRange.location < $1.declarationRange.location
            }, references: references,
            scopes: scopes.map {
                PL0SemanticScope(
                    id: $0.id, parentID: $0.parentID,
                    range: SourceRange(location: $0.start,
                                       length: max(0, $0.end - $0.start)),
                    symbolIDs: $0.symbolIDs)
            }, semanticTokens: semanticTokens,
            diagnostics: diagnostics)
    }

    private func emptyModel() -> PL0SemanticModel {
        PL0SemanticModel(version: prepared.snapshot.version,
                         grammarFingerprint: prepared.grammarFingerprint,
                         symbols: [], references: [], scopes: [],
                         semanticTokens: [], diagnostics: [])
    }

    private func parseBlock(parent: Int?) {
        let scopeID = scopes.count
        let level = parent.map { scopes[$0].level + 1 } ?? 0
        scopes.append(Scope(id: scopeID, parentID: parent, level: level,
                            start: current.range.location,
                            end: current.range.location))
        scopeStack.append(scopeID)
        if consume(.const) {
            repeat {
                if current.kind == .identifier {
                    let name = current
                    advance()
                    skip(.equal)
                    let value = current.kind == .number ? Int(current.lexeme) : nil
                    declare(name, kind: .constant, constantValue: value)
                    if current.kind == .number {
                        validateInteger(current)
                        advance()
                    }
                }
            } while consume(.comma)
            skip(.semicolon)
        }
        if consume(.varKeyword) {
            repeat {
                if current.kind == .identifier {
                    declare(current, kind: .variable)
                    advance()
                }
            } while consume(.comma)
            skip(.semicolon)
        }
        while consume(.procedure) {
            if current.kind == .identifier {
                declare(current, kind: .procedure)
                advance()
            }
            skip(.semicolon)
            parseBlock(parent: scopeID)
            skip(.semicolon)
        }
        parseStatement()
        scopes[scopeID].end = current.range.location
        scopeStack.removeLast()
    }

    private func parseStatement() {
        switch current.kind {
        case .identifier:
            reference(current, required: .variable)
            advance(); skip(.assign); parseExpression()
        case .call:
            advance()
            if current.kind == .identifier {
                reference(current, required: .procedure)
                advance()
            }
        case .begin:
            advance()
            if current.kind != .end { parseStatement() }
            while consume(.semicolon) { parseStatement() }
            skip(.end)
        case .ifKeyword:
            advance(); parseCondition(); skip(.then); parseStatement()
        case .whileKeyword:
            advance(); parseCondition(); skip(.doKeyword); parseStatement()
        default: break
        }
    }

    private func parseCondition() {
        if consume(.odd) { parseExpression(); return }
        parseExpression()
        if current.kind.isRelationalOperator { advance(); parseExpression() }
    }

    private func parseExpression() {
        if current.kind == .plus || current.kind == .minus { advance() }
        parseTerm()
        while current.kind == .plus || current.kind == .minus {
            advance(); parseTerm()
        }
    }

    private func parseTerm() {
        parseFactor()
        while current.kind == .star || current.kind == .slash {
            advance(); parseFactor()
        }
    }

    private func parseFactor() {
        if current.kind == .identifier {
            reference(current, valueContext: true)
            advance()
        } else if current.kind == .number {
            validateInteger(current)
            advance()
        } else if consume(.leftParen) {
            parseExpression(); skip(.rightParen)
        } else if current.kind != .endOfFile {
            advance()
        }
    }

    private func declare(_ token: PL0Token, kind: PL0SymbolKind,
                         constantValue: Int? = nil) {
        guard let scopeID = scopeStack.last else { return }
        let key = token.lexeme.lowercased()
        guard scopes[scopeID].symbols[key] == nil else {
            diagnose("Duplicate declaration of '\(token.lexeme)'", at: token.range)
            return
        }
        let slot: Int?
        if kind == .variable {
            slot = scopes[scopeID].nextVariableSlot
            scopes[scopeID].nextVariableSlot += 1
        } else {
            slot = nil
        }
        let symbol = PL0Symbol(
            id: token.id, name: token.lexeme, kind: kind,
            declarationRange: token.range, scopeID: scopeID,
            lexicalLevel: scopes[scopeID].level, slot: slot,
            constantValue: constantValue)
        symbols[symbol.id] = symbol
        scopes[scopeID].symbols[key] = symbol.id
        scopes[scopeID].symbolIDs.append(symbol.id)
        semanticTokens.append(PL0SemanticToken(
            range: token.range, classification: .symbol(kind),
            isDeclaration: true))
    }

    private func reference(_ token: PL0Token,
                           required: PL0SymbolKind? = nil,
                           valueContext: Bool = false) {
        guard let symbol = resolve(token.lexeme) else {
            diagnose("Unknown identifier '\(token.lexeme)'", at: token.range)
            return
        }
        if let required, symbol.kind != required {
            diagnose("'\(token.lexeme)' is not a \(required.rawValue)", at: token.range)
        } else if valueContext, symbol.kind == .procedure {
            diagnose("Procedure '\(token.lexeme)' is not a value", at: token.range)
        }
        references.append(PL0SymbolReference(
            range: token.range, symbolID: symbol.id))
        semanticTokens.append(PL0SemanticToken(
            range: token.range, classification: .symbol(symbol.kind),
            isDeclaration: false))
    }

    private func resolve(_ name: String) -> PL0Symbol? {
        let key = name.lowercased()
        for scopeID in scopeStack.reversed() {
            if let id = scopes[scopeID].symbols[key] { return symbols[id] }
        }
        return nil
    }

    private func validateInteger(_ token: PL0Token) {
        if Int(token.lexeme) == nil {
            diagnose("Integer literal is outside the VM range", at: token.range)
        }
    }

    private func diagnose(_ message: String, at range: SourceRange) {
        diagnostics.append(ParseDiagnostic(
            severity: .error, message: message, range: range))
    }

    private func classification(_ kind: PL0TokenKind) -> PL0SemanticClassification? {
        switch kind {
        case .const, .varKeyword, .procedure, .call, .begin, .end,
             .ifKeyword, .then, .whileKeyword, .doKeyword, .odd:
            .keyword
        case .number: .number
        case .plus, .minus, .star, .slash, .equal, .notEqual, .less,
             .lessEqual, .greater, .greaterEqual, .assign:
            .operatorToken
        default: nil
        }
    }

    private func consume(_ kind: PL0TokenKind) -> Bool {
        guard current.kind == kind else { return false }
        advance(); return true
    }

    private func skip(_ kind: PL0TokenKind) {
        if current.kind == kind { advance() }
    }

    private func advance() {
        if current.kind != .endOfFile { index += 1 }
    }
}
