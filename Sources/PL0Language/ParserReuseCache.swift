import Foundation

enum ReferenceParserRule: String, Sendable, Hashable {
    case block
    case statement
    case condition
    case expression
    case term
    case factor
}

struct ReferenceParserCache: Sendable {
    struct Key: Sendable, Hashable {
        let rule: ReferenceParserRule
        let startTokenID: String
    }

    struct Entry: Sendable {
        let tokenIDs: [String]
        let tokenRelativeLocations: [Int]
        let nextTokenID: String
        let nextTokenRelativeLocation: Int
        let startLocation: Int
        let node: SyntaxNode
        let diagnostics: [ParseDiagnostic]
        let recoveries: [RecoveryAction]
        let expectations: [ParseExpectation]
    }

    var entries: [Key: Entry] = [:]
    var isEmpty: Bool { entries.isEmpty }
}

struct ReferenceParserRun {
    let output: ParserOutput
    let cache: ReferenceParserCache
}
