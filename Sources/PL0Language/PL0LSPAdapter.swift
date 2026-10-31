import Foundation

// MARK: - Transport-neutral LSP values

public struct LSPPosition: Sendable, Equatable, Hashable {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

public struct LSPRange: Sendable, Equatable, Hashable {
    public let start: LSPPosition
    public let end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

public struct LSPDiagnostic: Sendable, Equatable, Identifiable {
    public let range: LSPRange
    public let severity: DiagnosticSeverity
    public let message: String
    public let source: String
    public var id: String { "\(range):\(message)" }
}

public enum LSPCompletionKind: String, Sendable {
    case keyword, constant, variable, function
}

public struct LSPCompletionItem: Sendable, Equatable, Identifiable {
    public let label: String
    public let kind: LSPCompletionKind
    public let detail: String
    public let insertText: String
    public var id: String { "\(kind.rawValue):\(label.lowercased())" }
}

public struct LSPLocation: Sendable, Equatable {
    public let uri: String
    public let range: LSPRange
}

public enum LSPSemanticTokenType: String, Sendable, CaseIterable {
    case keyword, number, operatorToken = "operator"
    case variable, constant, function
}

public struct LSPSemanticToken: Sendable, Equatable, Identifiable {
    public let range: LSPRange
    public let type: LSPSemanticTokenType
    public let isDeclaration: Bool
    public var id: String { "\(range):\(type.rawValue):\(isDeclaration)" }
}

public struct LSPTextChange: Sendable, Equatable {
    /// `nil` represents the full-document replacement form from LSP.
    public let range: LSPRange?
    public let text: String

    public init(range: LSPRange? = nil, text: String) {
        self.range = range
        self.text = text
    }
}

public enum PL0LSPError: Error, Sendable, Equatable, CustomStringConvertible {
    case documentNotOpen(String)
    case staleVersion(current: UInt64, received: UInt64)
    case invalidRange(LSPRange)

    public var description: String {
        switch self {
        case let .documentNotOpen(uri): "Document is not open: \(uri)"
        case let .staleVersion(current, received):
            "Document version \(received) is not newer than \(current)"
        case let .invalidRange(range): "Invalid LSP range: \(range)"
        }
    }
}

/// Converts between LSP's zero-based UTF-16 line/character pairs and the
/// absolute UTF-16 ranges used by the lexer, parser and TextKit.
public struct LSPLineMap: Sendable {
    private let codeUnits: [UInt16]
    private let starts: [Int]

    public init(_ source: String) {
        codeUnits = Array(source.utf16)
        var result = [0]
        var index = 0
        while index < codeUnits.count {
            let value = codeUnits[index]
            if value == 13 { // CR and CRLF are one line break.
                index += 1
                if index < codeUnits.count, codeUnits[index] == 10 { index += 1 }
                result.append(index)
            } else if value == 10 {
                index += 1
                result.append(index)
            } else {
                index += 1
            }
        }
        starts = result
    }

    public func offset(of position: LSPPosition) -> Int? {
        guard position.line >= 0, position.line < starts.count,
              position.character >= 0 else { return nil }
        let start = starts[position.line]
        let contentEnd = lineContentEnd(position.line)
        guard position.character <= contentEnd - start else { return nil }
        return start + position.character
    }

    public func position(of requestedOffset: Int) -> LSPPosition {
        let offset = min(max(0, requestedOffset), codeUnits.count)
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        let line = max(0, low - 1)
        return LSPPosition(line: line, character: offset - starts[line])
    }

    public func lspRange(_ range: SourceRange) -> LSPRange {
        LSPRange(start: position(of: range.location), positionEnd: position(of: range.end))
    }

    private func lineContentEnd(_ line: Int) -> Int {
        guard line + 1 < starts.count else { return codeUnits.count }
        var end = starts[line + 1]
        if end > starts[line], codeUnits[end - 1] == 10 { end -= 1 }
        if end > starts[line], codeUnits[end - 1] == 13 { end -= 1 }
        return end
    }
}

private extension LSPRange {
    init(start: LSPPosition, positionEnd: LSPPosition) {
        self.init(start: start, end: positionEnd)
    }
}

// MARK: - Versioned adapter

/// An actor suitable for direct editor use or for wrapping in JSON-RPC. It
/// deliberately contains no AppKit or transport code.
public actor PL0LSPAdapter {
    private struct Document: Sendable {
        var version: UInt64
        var text: String
        var parse: ParseResult
        var symbols: SymbolIndex
    }

    private var documents: [String: Document] = [:]
    private let frontend: PL0Frontend

    public init() {
        frontend = PL0Frontend()
    }

    public init(frontend: PL0Frontend) {
        self.frontend = frontend
    }

    @discardableResult
    public func open(uri: String, version: UInt64, text: String) -> [LSPDiagnostic] {
        let document = analyze(version: version, text: text)
        documents[uri] = document
        return diagnostics(for: document)
    }

    @discardableResult
    public func change(uri: String, version: UInt64,
                       changes: [LSPTextChange]) throws -> [LSPDiagnostic] {
        guard var document = documents[uri] else { throw PL0LSPError.documentNotOpen(uri) }
        guard version > document.version else {
            throw PL0LSPError.staleVersion(current: document.version, received: version)
        }
        for change in changes {
            if let range = change.range {
                let map = LSPLineMap(document.text)
                guard let start = map.offset(of: range.start),
                      let end = map.offset(of: range.end), end >= start else {
                    throw PL0LSPError.invalidRange(range)
                }
                document.text = (document.text as NSString).replacingCharacters(
                    in: NSRange(location: start, length: end - start), with: change.text)
            } else {
                document.text = change.text
            }
        }
        document = analyze(version: version, text: document.text)
        documents[uri] = document
        return diagnostics(for: document)
    }

    public func close(uri: String) { documents.removeValue(forKey: uri) }

    public func diagnostics(uri: String) throws -> [LSPDiagnostic] {
        guard let document = documents[uri] else { throw PL0LSPError.documentNotOpen(uri) }
        return diagnostics(for: document)
    }

    public func completions(uri: String, at position: LSPPosition) throws -> [LSPCompletionItem] {
        guard let document = documents[uri] else { throw PL0LSPError.documentNotOpen(uri) }
        guard let offset = LSPLineMap(document.text).offset(of: position) else {
            throw PL0LSPError.invalidRange(LSPRange(start: position, end: position))
        }
        let keywords = ["begin", "call", "const", "do", "end", "if", "odd",
                        "procedure", "then", "var", "while"].map {
            LSPCompletionItem(label: $0, kind: .keyword,
                              detail: "PL/0 keyword", insertText: $0)
        }
        return (keywords + document.symbols.visible(at: offset).map { symbol in
            LSPCompletionItem(label: symbol.name, kind: symbol.kind.completionKind,
                              detail: symbol.kind.detail, insertText: symbol.name)
        }).uniquedByID().sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    public func definition(uri: String, at position: LSPPosition) throws -> LSPLocation? {
        guard let document = documents[uri] else { throw PL0LSPError.documentNotOpen(uri) }
        let map = LSPLineMap(document.text)
        guard let offset = map.offset(of: position) else {
            throw PL0LSPError.invalidRange(LSPRange(start: position, end: position))
        }
        guard let reference = document.symbols.references.first(where: {
            offset >= $0.range.location && offset <= $0.range.end
        }), let declaration = document.symbols.declarations[reference.declarationID] else { return nil }
        return LSPLocation(uri: uri, range: map.lspRange(declaration.range))
    }

    public func semanticTokens(uri: String) throws -> [LSPSemanticToken] {
        guard let document = documents[uri] else { throw PL0LSPError.documentNotOpen(uri) }
        let map = LSPLineMap(document.text)
        return document.symbols.semanticTokens.map {
            LSPSemanticToken(range: map.lspRange($0.range), type: $0.type,
                             isDeclaration: $0.isDeclaration)
        }
    }

    public func snapshot(uri: String) throws -> SourceSnapshot {
        guard let document = documents[uri] else { throw PL0LSPError.documentNotOpen(uri) }
        return SourceSnapshot(version: document.version, text: document.text)
    }

    private func analyze(version: UInt64, text: String) -> Document {
        let snapshot = SourceSnapshot(version: version, text: text)
        let parse = frontend.parse(snapshot)
        return Document(version: version, text: text, parse: parse,
                        symbols: SymbolIndexer(tokens: parse.tokens).build())
    }

    private func diagnostics(for document: Document) -> [LSPDiagnostic] {
        let map = LSPLineMap(document.text)
        var result = document.parse.diagnostics.map {
            LSPDiagnostic(range: map.lspRange($0.range), severity: $0.severity,
                          message: $0.message, source: "pl0-parser")
        }
        result.append(contentsOf: document.symbols.diagnostics.map {
            LSPDiagnostic(range: map.lspRange($0.range), severity: .error,
                          message: $0.message, source: "pl0-semantics")
        })
        return result.uniquedByID()
    }
}

// MARK: - Lexical symbol index

private enum SymbolKind: Sendable {
    case constant, variable, procedure

    var completionKind: LSPCompletionKind {
        switch self { case .constant: .constant; case .variable: .variable; case .procedure: .function }
    }
    var semanticType: LSPSemanticTokenType {
        switch self { case .constant: .constant; case .variable: .variable; case .procedure: .function }
    }
    var detail: String {
        switch self { case .constant: "constant"; case .variable: "variable"; case .procedure: "procedure" }
    }
}

private struct IndexedSymbol: Sendable {
    let id: Int
    let name: String
    let kind: SymbolKind
    let range: SourceRange
    let scopeID: Int
}

private struct SymbolReference: Sendable {
    let range: SourceRange
    let declarationID: Int
}

private struct IndexedSemanticToken: Sendable {
    let range: SourceRange
    let type: LSPSemanticTokenType
    let isDeclaration: Bool
}

private struct SemanticDiagnostic: Sendable {
    let range: SourceRange
    let message: String
}

private struct IndexedScope: Sendable {
    let id: Int
    let parentID: Int?
    var range: SourceRange
    var symbols: [String: Int] = [:]
}

private struct SymbolIndex: Sendable {
    var declarations: [Int: IndexedSymbol] = [:]
    var references: [SymbolReference] = []
    var scopes: [IndexedScope] = []
    var semanticTokens: [IndexedSemanticToken] = []
    var diagnostics: [SemanticDiagnostic] = []

    func visible(at offset: Int) -> [IndexedSymbol] {
        guard var scope = scopes.filter({ offset >= $0.range.location && offset <= $0.range.end })
            .max(by: { $0.range.length > $1.range.length }) else { return [] }
        var result: [IndexedSymbol] = []
        var names = Set<String>()
        while true {
            for (name, id) in scope.symbols where names.insert(name).inserted {
                if let symbol = declarations[id] { result.append(symbol) }
            }
            guard let parent = scope.parentID, parent < scopes.count else { break }
            scope = scopes[parent]
        }
        return result
    }
}

private final class SymbolIndexer {
    private let tokens: [PL0Token]
    private var index = 0
    private var result = SymbolIndex()
    private var scopeStack: [Int] = []

    init(tokens: [PL0Token]) { self.tokens = tokens }
    private var current: PL0Token { tokens[min(index, tokens.count - 1)] }

    func build() -> SymbolIndex {
        parseBlock(parent: nil)
        for token in tokens where token.kind != .identifier && token.kind != .endOfFile {
            if let type = semanticType(token.kind) {
                result.semanticTokens.append(IndexedSemanticToken(
                    range: token.range, type: type, isDeclaration: false))
            }
        }
        result.semanticTokens.sort { $0.range.location < $1.range.location }
        return result
    }

    private func parseBlock(parent: Int?) {
        let start = current.range.location
        let scopeID = result.scopes.count
        result.scopes.append(IndexedScope(id: scopeID, parentID: parent,
                                          range: SourceRange(location: start, length: 0)))
        scopeStack.append(scopeID)
        if consume(.const) {
            repeat {
                if current.kind == .identifier { declare(current, kind: .constant); advance() }
                skip(.equal); skip(.number)
            } while consume(.comma)
            skip(.semicolon)
        }
        if consume(.varKeyword) {
            repeat {
                if current.kind == .identifier { declare(current, kind: .variable); advance() }
            } while consume(.comma)
            skip(.semicolon)
        }
        while consume(.procedure) {
            if current.kind == .identifier { declare(current, kind: .procedure); advance() }
            skip(.semicolon)
            parseBlock(parent: scopeID)
            skip(.semicolon)
        }
        parseStatement()
        let end = current.range.location
        result.scopes[scopeID].range = SourceRange(location: start, length: max(0, end - start))
        scopeStack.removeLast()
    }

    private func parseStatement() {
        switch current.kind {
        case .identifier:
            reference(current, required: .variable); advance(); skip(.assign); parseExpression()
        case .call:
            advance()
            if current.kind == .identifier { reference(current, required: .procedure); advance() }
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
        while current.kind == .plus || current.kind == .minus { advance(); parseTerm() }
    }

    private func parseTerm() {
        parseFactor()
        while current.kind == .star || current.kind == .slash { advance(); parseFactor() }
    }

    private func parseFactor() {
        if current.kind == .identifier {
            reference(current, required: nil); advance()
        } else if current.kind == .number {
            advance()
        } else if consume(.leftParen) {
            parseExpression(); skip(.rightParen)
        } else if current.kind != .endOfFile {
            advance()
        }
    }

    private func declare(_ token: PL0Token, kind: SymbolKind) {
        guard let scopeID = scopeStack.last else { return }
        let key = token.lexeme.lowercased()
        if result.scopes[scopeID].symbols[key] != nil {
            result.diagnostics.append(SemanticDiagnostic(
                range: token.range, message: "Duplicate declaration of '\(token.lexeme)'"))
            return
        }
        let id = result.declarations.count
        let symbol = IndexedSymbol(id: id, name: token.lexeme, kind: kind,
                                   range: token.range, scopeID: scopeID)
        result.declarations[id] = symbol
        result.scopes[scopeID].symbols[key] = id
        result.semanticTokens.append(IndexedSemanticToken(
            range: token.range, type: kind.semanticType, isDeclaration: true))
    }

    private func reference(_ token: PL0Token, required: SymbolKind?) {
        guard let symbol = resolve(token.lexeme) else {
            result.diagnostics.append(SemanticDiagnostic(
                range: token.range, message: "Unknown identifier '\(token.lexeme)'"))
            return
        }
        if let required, !sameKind(symbol.kind, required) {
            result.diagnostics.append(SemanticDiagnostic(
                range: token.range,
                message: "'\(token.lexeme)' is not a \(required.detail)"))
        }
        result.references.append(SymbolReference(range: token.range,
                                                 declarationID: symbol.id))
        result.semanticTokens.append(IndexedSemanticToken(
            range: token.range, type: symbol.kind.semanticType, isDeclaration: false))
    }

    private func resolve(_ name: String) -> IndexedSymbol? {
        let key = name.lowercased()
        for scopeID in scopeStack.reversed() {
            if let id = result.scopes[scopeID].symbols[key] { return result.declarations[id] }
        }
        return nil
    }

    private func sameKind(_ lhs: SymbolKind, _ rhs: SymbolKind) -> Bool {
        switch (lhs, rhs) {
        case (.constant, .constant), (.variable, .variable), (.procedure, .procedure): true
        default: false
        }
    }

    private func semanticType(_ kind: PL0TokenKind) -> LSPSemanticTokenType? {
        switch kind {
        case .const, .varKeyword, .procedure, .call, .begin, .end,
             .ifKeyword, .then, .whileKeyword, .doKeyword, .odd: .keyword
        case .number: .number
        case .plus, .minus, .star, .slash, .equal, .notEqual, .less,
             .lessEqual, .greater, .greaterEqual, .assign: .operatorToken
        default: nil
        }
    }

    private func consume(_ kind: PL0TokenKind) -> Bool {
        guard current.kind == kind else { return false }
        advance(); return true
    }
    private func skip(_ kind: PL0TokenKind) { if current.kind == kind { advance() } }
    private func advance() { if current.kind != .endOfFile { index += 1 } }
}

private extension Array where Element: Identifiable, Element.ID: Hashable {
    func uniquedByID() -> [Element] {
        var ids = Set<Element.ID>()
        return filter { ids.insert($0.id).inserted }
    }
}
