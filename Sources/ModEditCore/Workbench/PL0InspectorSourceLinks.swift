import Foundation
import PL0Language

struct PL0InspectorSourceLinks: Sendable {
    struct Row: Identifiable, Sendable {
        let id: String
        let label: String
        let range: SourceRange
        var depth = 0
    }

    struct Highlight {
        var tokenIDs: Set<String> = []
        var tokenAnchor: String?
        var syntaxIDs: Set<String> = []
        var syntaxAnchor: String?
    }

    let tokens: [Row]
    let nodes: [Row]
    let terminals: [Row]

    init(_ result: ParseResult) {
        func spelling(_ lexeme: String, fallback: String) -> String {
            lexeme.isEmpty ? fallback : String(reflecting: lexeme)
        }
        tokens = result.tokens.map {
            .init(id: "token:\($0.id)",
                  label: "\($0.kind.rawValue)  \(spelling($0.lexeme, fallback: "<eof>"))",
                  range: $0.range)
        }
        var rows: [Row] = []
        func append(_ node: SyntaxNode, depth: Int) {
            let marker = node.origin == .recovered ? " [recovered]" : ""
            rows.append(.init(id: "node:\(rows.count)", label: node.kind + marker,
                              range: node.range, depth: depth))
            for child in node.children { append(child, depth: depth + 1) }
        }
        append(result.root, depth: 0)
        nodes = rows
        terminals = result.syntaxTree.terminals.map {
            let marker = $0.disposition == .source ? "" : " [\($0.disposition.rawValue)]"
            return .init(id: "terminal:\($0.id)",
                         label: "\($0.kind.rawValue)  \(spelling($0.lexeme, fallback: $0.kind.displayName))\(marker)",
                         range: $0.range)
        }
    }

    func highlight(selection: NSRange, explicit: Row?) -> Highlight {
        var result = Highlight()
        let matchingTokens: [Row]
        let matchingTerminals: [Row]
        let range = explicit?.range
        if let explicit, explicit.id.hasPrefix("terminal:") || explicit.id.hasPrefix("token:") {
            let identity = explicit.id.split(separator: ":", maxSplits: 1)[1]
            matchingTokens = tokens.filter { $0.id == "token:\(identity)" }
            matchingTerminals = terminals.filter { $0.id == "terminal:\(identity)" }
        } else {
            let location = range?.location ?? selection.location
            let length = range?.length ?? selection.length
            func matches(_ row: Row) -> Bool {
                // A caret in trivia has no source token. Missing terminals
                // can still be selected explicitly from the CST.
                guard row.range.length > 0 else { return false }
                if length == 0 {
                    return row.range.location <= location && location < row.range.end
                }
                return row.range.location < location + length && location < row.range.end
            }
            matchingTokens = tokens.filter(matches)
            matchingTerminals = terminals.filter(matches)
        }
        result.tokenIDs = Set(matchingTokens.map(\.id))
        result.tokenAnchor = matchingTokens.first?.id
        result.syntaxIDs = Set(matchingTerminals.map(\.id))

        if let explicit, explicit.id.hasPrefix("node:") {
            result.syntaxIDs.insert(explicit.id)
            result.syntaxAnchor = explicit.id
        } else {
            let anchor = range ?? matchingTokens.first?.range
            if let anchor, let node = nodes.lazy.filter({
                $0.range.location <= anchor.location && $0.range.end >= anchor.end
                    && ($0.range.length > 0 || $0.range.location == anchor.location)
            }).max(by: { $0.depth < $1.depth }) {
                result.syntaxIDs.insert(node.id)
                result.syntaxAnchor = node.id
            }
            if explicit?.id.hasPrefix("terminal:") == true {
                result.syntaxAnchor = explicit?.id
            } else if explicit != nil || result.syntaxAnchor == nil {
                result.syntaxAnchor = matchingTerminals.first?.id ?? result.syntaxAnchor
            }
        }
        return result
    }
}
