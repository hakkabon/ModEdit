import Foundation
import LanguageExperimentProtocol

public enum PL0LanguageKitError: Error, Sendable, Equatable, CustomStringConvertible {
    case resourceMissing
    case malformedDirective(line: Int, text: String)
    case malformedProduction(String)
    case duplicateToken(String)
    case duplicateOrMissingStart(String)
    case unknownSymbol(production: String, symbol: String)
    case unsupportedToken(String)
    case typedBindingMismatch(missing: [String], unexpected: [String])
    case artifactMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .resourceMissing: "The bundled PL0.grammar resource is missing."
        case let .malformedDirective(line, text): "Malformed grammar directive at line \(line): \(text)"
        case let .malformedProduction(text): "Malformed grammar production: \(text)"
        case let .duplicateToken(name): "Duplicate grammar token \(name)."
        case let .duplicateOrMissingStart(name): "The start symbol '\(name)' is missing or ambiguous."
        case let .unknownSymbol(production, symbol): "Production \(production) refers to unknown symbol \(symbol)."
        case let .unsupportedToken(name): "Token \(name) has no typed PL/0 binding."
        case let .typedBindingMismatch(missing, unexpected):
            "PL/0 typed grammar bindings differ (missing: \(missing), unexpected: \(unexpected))."
        case let .artifactMismatch(expected, actual):
            "Grammar artifact mismatch: expected \(expected), received \(actual)."
        }
    }
}

public struct PL0TokenDefinition: Sendable, Equatable, Hashable {
    public let name: String
    public let pattern: String
    public let kind: PL0TokenKind
}

public enum PL0GrammarSymbolDefinition: Sendable, Equatable, Hashable {
    case terminal(name: String, kind: PL0TokenKind)
    case nonterminal(String)
}

public struct PL0ProductionDefinition: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let lhs: String
    public let rhs: [PL0GrammarSymbolDefinition]
}

public struct PL0GrammarArtifact: Sendable, Equatable {
    public let artifactID: String
    public let revision: UInt64
    public let source: String
    public let fingerprint: String
    public let startSymbol: String
    public let tokenDefinitions: [PL0TokenDefinition]
    public let skipPatterns: [String]
    public let productions: [PL0ProductionDefinition]

    public var grammarIdentity: GrammarArtifactIdentity {
        // Compilation has already validated these values.
        try! .sourceArtifact(id: artifactID, languageID: "pl0",
                             revision: revision, notation: "Workbench",
                             source: source, normalForm: "BNF")
    }

    public func requireFingerprint(_ fingerprint: String) throws {
        guard self.fingerprint == fingerprint else {
            throw PL0LanguageKitError.artifactMismatch(
                expected: self.fingerprint, actual: fingerprint)
        }
    }
}

/// A compiled, immutable PL/0 language definition. The bundled grammar is the
/// single source used for token classification, generated parser productions,
/// Workbench interchange, and experiment identity.
public struct PL0LanguageKit: Sendable, Equatable {
    public static let artifactID = "org.hakkabon.modedit.pl0"

    public static let bundled: PL0LanguageKit = {
        do { return try loadBundled() }
        catch { preconditionFailure("Invalid bundled PL/0 language kit: \(error)") }
    }()

    public let artifact: PL0GrammarArtifact
    let keywordKinds: [String: PL0TokenKind]
    let operatorKinds: [String: PL0TokenKind]

    public var keywordSpellings: [String] { keywordKinds.keys.sorted() }

    public static func loadBundled() throws -> PL0LanguageKit {
        guard let url = Bundle.module.url(forResource: "PL0", withExtension: "grammar") else {
            throw PL0LanguageKitError.resourceMissing
        }
        return try compile(source: String(contentsOf: url, encoding: .utf8))
    }

    public static func compile(source: String, revision: UInt64 = 1,
                               artifactID: String = artifactID) throws -> PL0LanguageKit {
        let raw = try GrammarSourceParser(source: source).parse()
        let typedNames = Set(PL0TokenKind.grammarTerminals.map(\.grammarName))
        let declaredNames = Set(raw.tokens.map(\.name))
        let missing = typedNames.subtracting(declaredNames).sorted()
        let unexpected = declaredNames.subtracting(typedNames).sorted()
        guard missing.isEmpty, unexpected.isEmpty else {
            throw PL0LanguageKitError.typedBindingMismatch(
                missing: missing, unexpected: unexpected)
        }

        let definitions = try raw.tokens.map { token -> PL0TokenDefinition in
            guard let kind = PL0TokenKind(grammarName: token.name) else {
                throw PL0LanguageKitError.unsupportedToken(token.name)
            }
            return PL0TokenDefinition(name: token.name, pattern: token.pattern, kind: kind)
        }
        let nonterminals = Set(raw.productions.map(\.lhs))
        guard nonterminals.contains(raw.start) else {
            throw PL0LanguageKitError.duplicateOrMissingStart(raw.start)
        }
        var productions: [PL0ProductionDefinition] = []
        for (ordinal, production) in raw.productions.enumerated() {
            var symbols: [PL0GrammarSymbolDefinition] = []
            for symbol in production.rhs {
                if declaredNames.contains(symbol) {
                    guard let kind = PL0TokenKind(grammarName: symbol) else {
                        throw PL0LanguageKitError.unsupportedToken(symbol)
                    }
                    symbols.append(.terminal(name: symbol, kind: kind))
                } else if nonterminals.contains(symbol) {
                    symbols.append(.nonterminal(symbol))
                } else {
                    throw PL0LanguageKitError.unknownSymbol(
                        production: production.lhs, symbol: symbol)
                }
            }
            productions.append(PL0ProductionDefinition(
                id: "p\(ordinal):\(production.lhs)", lhs: production.lhs, rhs: symbols))
        }
        let actualNonterminals = Set(PL0Nonterminal.allCases.map(\.rawValue))
        let missingNonterminals = actualNonterminals.subtracting(nonterminals).sorted()
        let unexpectedNonterminals = nonterminals.subtracting(actualNonterminals).sorted()
        guard missingNonterminals.isEmpty, unexpectedNonterminals.isEmpty else {
            throw PL0LanguageKitError.typedBindingMismatch(
                missing: missingNonterminals, unexpected: unexpectedNonterminals)
        }

        var keywords: [String: PL0TokenKind] = [:]
        var operators: [String: PL0TokenKind] = [:]
        for definition in definitions {
            guard let literal = regexLiteral(definition.pattern) else { continue }
            if literal.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
                keywords[literal.lowercased()] = definition.kind
            } else {
                operators[literal] = definition.kind
            }
        }
        let artifact = PL0GrammarArtifact(
            artifactID: artifactID, revision: revision, source: source,
            fingerprint: StableFingerprint.fnv1a64(source),
            startSymbol: raw.start, tokenDefinitions: definitions,
            skipPatterns: raw.skips, productions: productions)
        return PL0LanguageKit(artifact: artifact,
                              keywordKinds: keywords, operatorKinds: operators)
    }

    public func requireArtifact(_ identity: GrammarArtifactIdentity) throws {
        guard identity.artifactID == artifact.artifactID,
              identity.revision == artifact.revision else {
            throw PL0LanguageKitError.artifactMismatch(
                expected: "\(artifact.artifactID)@\(artifact.revision)",
                actual: "\(identity.artifactID)@\(identity.revision)")
        }
        try artifact.requireFingerprint(identity.fingerprint)
    }

    func keywordKind(_ spelling: String) -> PL0TokenKind? {
        keywordKinds[spelling.lowercased()]
    }

    func operatorKind(_ spelling: String) -> PL0TokenKind? {
        operatorKinds[spelling]
    }
}

public enum PL0Nonterminal: String, CaseIterable, Sendable {
    case program = "Program"
    case block = "Block"
    case constPart = "ConstPart"
    case constDefinition = "ConstDefinition"
    case moreConsts = "MoreConsts"
    case varPart = "VarPart"
    case moreVars = "MoreVars"
    case procedures = "Procedures"
    case statement = "Statement"
    case moreStatements = "MoreStatements"
    case condition = "Condition"
    case relation = "Relation"
    case expression = "Expression"
    case sign = "Sign"
    case moreTerms = "MoreTerms"
    case term = "Term"
    case moreFactors = "MoreFactors"
    case factor = "Factor"
}

private struct RawGrammar {
    struct Token { let name: String; let pattern: String }
    struct Production { let lhs: String; let rhs: [String] }
    let start: String
    let tokens: [Token]
    let skips: [String]
    let productions: [Production]
}

private struct GrammarSourceParser {
    let source: String

    func parse() throws -> RawGrammar {
        var startSymbols: [String] = []
        var tokens: [RawGrammar.Token] = []
        var skips: [String] = []
        var productionLines: [String] = []
        for (index, substring) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("%start ") {
                startSymbols.append(String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("%token ") {
                let body = String(line.dropFirst(7))
                guard let separator = body.firstIndex(where: { $0 == " " || $0 == "\t" }),
                      let pattern = delimitedPattern(String(body[separator...])) else {
                    throw PL0LanguageKitError.malformedDirective(line: index + 1, text: line)
                }
                let name = String(body[..<separator])
                guard !tokens.contains(where: { $0.name == name }) else {
                    throw PL0LanguageKitError.duplicateToken(name)
                }
                tokens.append(.init(name: name, pattern: pattern))
            } else if line.hasPrefix("%skip ") {
                guard let pattern = delimitedPattern(String(line.dropFirst(6))) else {
                    throw PL0LanguageKitError.malformedDirective(line: index + 1, text: line)
                }
                skips.append(pattern)
            } else if line.hasPrefix("%") {
                throw PL0LanguageKitError.malformedDirective(line: index + 1, text: line)
            } else {
                productionLines.append(line)
            }
        }
        guard startSymbols.count == 1, let start = startSymbols.first else {
            throw PL0LanguageKitError.duplicateOrMissingStart(startSymbols.first ?? "")
        }
        var productions: [RawGrammar.Production] = []
        for statement in productionLines.joined(separator: " ").split(separator: ";", omittingEmptySubsequences: true) {
            let text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = text.firstIndex(of: ":") else {
                throw PL0LanguageKitError.malformedProduction(text)
            }
            let lhs = text[..<colon].trimmingCharacters(in: .whitespaces)
            guard !lhs.isEmpty else { throw PL0LanguageKitError.malformedProduction(text) }
            let body = text[text.index(after: colon)...]
            for alternative in body.split(separator: "|", omittingEmptySubsequences: false) {
                let rhs = alternative.split(whereSeparator: \Character.isWhitespace).map(String.init)
                productions.append(.init(lhs: lhs, rhs: rhs))
            }
        }
        return RawGrammar(start: start, tokens: tokens, skips: skips,
                          productions: productions)
    }
}

private func delimitedPattern(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.first == "/", trimmed.last == "/", trimmed.count >= 2 else { return nil }
    return String(trimmed.dropFirst().dropLast())
}

private func regexLiteral(_ pattern: String) -> String? {
    var result = ""
    var index = pattern.startIndex
    while index < pattern.endIndex {
        let character = pattern[index]
        if character == "\\" {
            let next = pattern.index(after: index)
            guard next < pattern.endIndex else { return nil }
            if pattern[next] == "b", pattern.index(after: next) == pattern.endIndex { break }
            result.append(pattern[next])
            index = pattern.index(after: next)
        } else {
            guard !"[]+*?(){}|.^$".contains(character) else { return nil }
            result.append(character)
            index = pattern.index(after: index)
        }
    }
    return result.isEmpty ? nil : result
}

extension PL0TokenKind {
    fileprivate static let grammarTerminals = allCases.filter {
        $0 != .invalid && $0 != .endOfFile
    }

    var grammarName: String {
        switch self {
        case .identifier: "IDENTIFIER"
        case .number: "NUMBER"
        case .const: "CONST"
        case .varKeyword: "VAR"
        case .procedure: "PROCEDURE"
        case .call: "CALL"
        case .begin: "BEGIN"
        case .end: "END"
        case .ifKeyword: "IF"
        case .then: "THEN"
        case .whileKeyword: "WHILE"
        case .doKeyword: "DO"
        case .odd: "ODD"
        case .plus: "PLUS"
        case .minus: "MINUS"
        case .star: "STAR"
        case .slash: "SLASH"
        case .equal: "EQUAL"
        case .notEqual: "NE"
        case .less: "LT"
        case .lessEqual: "LE"
        case .greater: "GT"
        case .greaterEqual: "GE"
        case .assign: "ASSIGN"
        case .comma: "COMMA"
        case .semicolon: "SEMICOLON"
        case .period: "PERIOD"
        case .leftParen: "LPAREN"
        case .rightParen: "RPAREN"
        case .invalid, .endOfFile: rawValue.uppercased()
        }
    }

    fileprivate init?(grammarName: String) {
        guard let kind = Self.grammarTerminals.first(where: { $0.grammarName == grammarName }) else {
            return nil
        }
        self = kind
    }
}
