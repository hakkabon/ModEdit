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

public struct LSPHover: Sendable, Equatable {
    public let contents: String
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

/// Standard LSP semantic-token integer stream. Token types use the order in
/// `LSPSemanticTokenType.allCases`; modifier bit zero means declaration.
public struct LSPSemanticTokensResult: Sendable, Equatable {
    public let resultID: String
    public let data: [Int]
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
        var analysis: PL0Analysis
        let session: PL0LanguageSession
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
    public func open(uri: String, version: UInt64,
                     text: String) async -> [LSPDiagnostic] {
        let session = PL0LanguageSession(
            engine: frontend.engine, languageKit: frontend.languageKit)
        let snapshot = SourceSnapshot(version: version, text: text)
        let document = Document(
            version: version, text: text,
            analysis: await session.analyze(snapshot), session: session)
        documents[uri] = document
        return diagnostics(for: document)
    }

    @discardableResult
    public func change(uri: String, version: UInt64,
                       changes: [LSPTextChange]) async throws -> [LSPDiagnostic] {
        guard var document = documents[uri] else { throw PL0LSPError.documentNotOpen(uri) }
        guard version > document.version else {
            throw PL0LSPError.staleVersion(current: document.version, received: version)
        }
        var sourceEdit: SourceEdit?
        for (changeIndex, change) in changes.enumerated() {
            let oldText = document.text
            if let range = change.range {
                let map = LSPLineMap(document.text)
                guard let start = map.offset(of: range.start),
                      let end = map.offset(of: range.end), end >= start else {
                    throw PL0LSPError.invalidRange(range)
                }
                document.text = (document.text as NSString).replacingCharacters(
                    in: NSRange(location: start, length: end - start), with: change.text)
                if changes.count == 1, changeIndex == 0 {
                    sourceEdit = SourceEdit(
                        baseVersion: document.version,
                        replacedRange: SourceRange(location: start, length: end - start),
                        replacementLength: change.text.utf16.count)
                }
            } else {
                document.text = change.text
                if changes.count == 1, changeIndex == 0 {
                    sourceEdit = SourceEdit(
                        baseVersion: document.version,
                        replacedRange: SourceRange(
                            location: 0, length: oldText.utf16.count),
                        replacementLength: change.text.utf16.count)
                }
            }
        }
        document.version = version
        document.analysis = await document.session.analyze(SourceSnapshot(
            version: version, text: document.text, edit: sourceEdit))
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
        let keywords = frontend.languageKit.keywordSpellings.map {
            LSPCompletionItem(label: $0, kind: .keyword,
                              detail: "PL/0 keyword", insertText: $0)
        }
        return (keywords + document.analysis.semantics.visibleSymbols(at: offset).map { symbol in
            LSPCompletionItem(label: symbol.name, kind: completionKind(symbol.kind),
                              detail: symbol.kind.rawValue, insertText: symbol.name)
        }).uniquedByID().sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    public func definition(uri: String, at position: LSPPosition) throws -> LSPLocation? {
        guard let document = documents[uri] else { throw PL0LSPError.documentNotOpen(uri) }
        let map = LSPLineMap(document.text)
        guard let offset = map.offset(of: position) else {
            throw PL0LSPError.invalidRange(LSPRange(start: position, end: position))
        }
        guard let declaration = document.analysis.semantics
            .declaration(referencedAt: offset) else { return nil }
        return LSPLocation(uri: uri,
                           range: map.lspRange(declaration.declarationRange))
    }

    public func hover(uri: String, at position: LSPPosition) throws -> LSPHover? {
        guard let document = documents[uri] else { throw PL0LSPError.documentNotOpen(uri) }
        let map = LSPLineMap(document.text)
        guard let offset = map.offset(of: position) else {
            throw PL0LSPError.invalidRange(LSPRange(start: position, end: position))
        }
        let semantics = document.analysis.semantics
        let symbol = semantics.declaration(referencedAt: offset)
            ?? semantics.symbols.first(where: {
                offset >= $0.declarationRange.location
                    && offset <= $0.declarationRange.end
            })
        guard let symbol else { return nil }
        var details = "\(symbol.kind.rawValue) \(symbol.name)"
        if let value = symbol.constantValue { details += " = \(value)" }
        if let slot = symbol.slot { details += " · level \(symbol.lexicalLevel), slot \(slot)" }
        return LSPHover(contents: details,
                        range: map.lspRange(symbol.declarationRange))
    }

    public func references(uri: String, at position: LSPPosition,
                           includeDeclaration: Bool = true) throws -> [LSPLocation] {
        guard let document = documents[uri] else { throw PL0LSPError.documentNotOpen(uri) }
        let map = LSPLineMap(document.text)
        guard let offset = map.offset(of: position) else {
            throw PL0LSPError.invalidRange(LSPRange(start: position, end: position))
        }
        let semantics = document.analysis.semantics
        let symbol = semantics.declaration(referencedAt: offset)
            ?? semantics.symbols.first(where: {
                offset >= $0.declarationRange.location
                    && offset <= $0.declarationRange.end
            })
        guard let symbol else { return [] }
        var ranges = semantics.references
            .filter { $0.symbolID == symbol.id }.map(\.range)
        if includeDeclaration { ranges.insert(symbol.declarationRange, at: 0) }
        return ranges.map { LSPLocation(uri: uri, range: map.lspRange($0)) }
    }

    public func semanticTokens(uri: String) throws -> [LSPSemanticToken] {
        guard let document = documents[uri] else { throw PL0LSPError.documentNotOpen(uri) }
        let map = LSPLineMap(document.text)
        return document.analysis.semantics.semanticTokens.compactMap {
            guard let type = semanticTokenType($0.classification) else { return nil }
            return LSPSemanticToken(range: map.lspRange($0.range), type: type,
                             isDeclaration: $0.isDeclaration)
        }
    }

    public func semanticTokenData(uri: String) throws -> LSPSemanticTokensResult {
        guard let document = documents[uri] else { throw PL0LSPError.documentNotOpen(uri) }
        let tokens = try semanticTokens(uri: uri).sorted {
            if $0.range.start.line == $1.range.start.line {
                $0.range.start.character < $1.range.start.character
            } else {
                $0.range.start.line < $1.range.start.line
            }
        }
        var previousLine = 0
        var previousCharacter = 0
        var data: [Int] = []
        for token in tokens where token.range.start.line == token.range.end.line {
            guard let typeIndex = LSPSemanticTokenType.allCases.firstIndex(of: token.type)
            else { continue }
            let deltaLine = token.range.start.line - previousLine
            let deltaCharacter = deltaLine == 0
                ? token.range.start.character - previousCharacter
                : token.range.start.character
            data += [deltaLine, deltaCharacter,
                     token.range.end.character - token.range.start.character,
                     typeIndex, token.isDeclaration ? 1 : 0]
            previousLine = token.range.start.line
            previousCharacter = token.range.start.character
        }
        return LSPSemanticTokensResult(
            resultID: "\(document.version):\(document.analysis.semantics.grammarFingerprint)",
            data: data)
    }

    public func snapshot(uri: String) throws -> SourceSnapshot {
        guard let document = documents[uri] else { throw PL0LSPError.documentNotOpen(uri) }
        return SourceSnapshot(version: document.version, text: document.text)
    }

    public func analysis(uri: String) throws -> PL0Analysis {
        guard let document = documents[uri] else {
            throw PL0LSPError.documentNotOpen(uri)
        }
        return document.analysis
    }

    private func diagnostics(for document: Document) -> [LSPDiagnostic] {
        let map = LSPLineMap(document.text)
        var result = document.analysis.parse.diagnostics.map {
            LSPDiagnostic(range: map.lspRange($0.range), severity: $0.severity,
                          message: $0.message, source: "pl0-parser")
        }
        result.append(contentsOf: document.analysis.semantics.diagnostics.map {
            LSPDiagnostic(range: map.lspRange($0.range), severity: .error,
                          message: $0.message, source: "pl0-semantics")
        })
        return result.uniquedByID()
    }

    private func completionKind(_ kind: PL0SymbolKind) -> LSPCompletionKind {
        switch kind {
        case .constant: .constant
        case .variable: .variable
        case .procedure: .function
        }
    }

    private func semanticTokenType(
        _ classification: PL0SemanticClassification
    ) -> LSPSemanticTokenType? {
        switch classification {
        case .keyword: .keyword
        case .number: .number
        case .operatorToken: .operatorToken
        case .symbol(.constant): .constant
        case .symbol(.variable): .variable
        case .symbol(.procedure): .function
        }
    }
}

private extension Array where Element: Identifiable, Element.ID: Hashable {
    func uniquedByID() -> [Element] {
        var ids = Set<Element.ID>()
        return filter { ids.insert($0.id).inserted }
    }
}
