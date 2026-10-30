import Foundation

/// Parser identity is explicit so the workbench can compare engines later
/// without changing its result model.
public enum ParserEngine: String, Sendable, CaseIterable {
    case referenceLL = "Reference LL"
}

/// Hand-written correctness oracle for the controlled PL/0 grammar. It is
/// intentionally conventional and deterministic so generated and generalized
/// parsers have an uncomplicated result to compare against.
public struct ReferencePL0Parser: PL0ParserProtocol {
    public let descriptor = ParserDescriptor(
        id: "reference-ll",
        displayName: "Reference LL",
        capabilities: [.deterministicTree, .errorRecovery, .expectedTokens])

    public init() {}

    public func parse(_ input: ParserInput) -> ParserOutput {
        ReferenceParser(tokens: normalized(input.tokens),
                        lexicalDiagnostics: input.lexicalDiagnostics).parseProgram()
    }

    private func normalized(_ tokens: [PL0Token]) -> [PL0Token] {
        guard tokens.last?.kind != .endOfFile else { return tokens }
        let last = tokens.last
        let offset = last?.range.end ?? 0
        let line = last?.location.line ?? 1
        let column = (last?.location.column ?? 1) + (last?.range.length ?? 0)
        let eof = PL0Token(id: "reference:eof:\(offset)", kind: .endOfFile, lexeme: "",
                           range: SourceRange(location: offset, length: 0),
                           location: SourceLocation(offset: offset, line: line, column: column))
        return tokens + [eof]
    }
}

/// Facade used by ModEdit and tests. The implementation is intentionally a
/// small reference recursive-descent parser: correctness and transparent
/// recovery matter more than cleverness at this stage.
public struct PL0Frontend: Sendable {
    public let engine: ParserEngine

    public init(engine: ParserEngine = .referenceLL) { self.engine = engine }

    public func parse(_ snapshot: SourceSnapshot) -> ParseResult {
        let clock = ContinuousClock()
        let lexStart = clock.now
        let lexed = PL0Lexer().tokenize(snapshot)
        let lexDuration = lexStart.duration(to: clock.now)
        let lexMetrics = IncrementalLexMetrics(
            scannedUTF16Length: snapshot.text.utf16.count,
            generatedTokenCount: lexed.tokens.count,
            reusedPrefixTokenCount: 0, reusedSuffixTokenCount: 0,
            converged: false, incremental: false)
        return parse(snapshot, lexed: lexed,
                     lexingNanoseconds: Self.nanoseconds(lexDuration),
                     lexMetrics: lexMetrics)
    }

    func parse(_ snapshot: SourceSnapshot, lexed: LexResult,
               lexingNanoseconds: UInt64,
               lexMetrics: IncrementalLexMetrics) -> ParseResult {
        let clock = ContinuousClock()
        let parseStart = clock.now
        let parser: any PL0ParserProtocol = switch engine {
        case .referenceLL: ReferencePL0Parser()
        }
        let parsed = parser.parse(ParserInput(tokens: lexed.tokens,
                                              lexicalDiagnostics: lexed.diagnostics))
        let parseDuration = parseStart.duration(to: clock.now)
        return ParseResult(
            version: snapshot.version, parser: parser.descriptor,
            tokens: lexed.tokens, root: parsed.root,
            diagnostics: parsed.diagnostics, recoveryActions: parsed.recoveryActions,
            expectations: parsed.expectations,
            metrics: ParseMetrics(
                sourceLength: snapshot.text.utf16.count,
                tokenCount: max(0, lexed.tokens.count - 1),
                lexingNanoseconds: lexingNanoseconds,
                parsingNanoseconds: Self.nanoseconds(parseDuration),
                recoveryCount: parsed.recoveryActions.count,
                incrementalLexing: lexMetrics))
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let parts = duration.components
        return UInt64(max(0, parts.seconds)) &* 1_000_000_000
            &+ UInt64(max(0, parts.attoseconds) / 1_000_000_000)
    }
}

/// Serializes incremental tokenizer state for one open document. The editor
/// may cancel an awaiting UI task without racing the token cache itself.
public actor PL0LanguageSession {
    private var tokenizer = PL0IncrementalTokenizer()
    private let frontend: PL0Frontend

    public init(engine: ParserEngine = .referenceLL) {
        frontend = PL0Frontend(engine: engine)
    }

    public func parse(_ snapshot: SourceSnapshot) -> ParseResult {
        let clock = ContinuousClock()
        let start = clock.now
        let tokenized = tokenizer.tokenize(snapshot)
        let duration = start.duration(to: clock.now)
        let parts = duration.components
        let nanoseconds = UInt64(max(0, parts.seconds)) &* 1_000_000_000
            &+ UInt64(max(0, parts.attoseconds) / 1_000_000_000)
        return frontend.parse(snapshot, lexed: tokenized.lexed,
                              lexingNanoseconds: nanoseconds,
                              lexMetrics: tokenized.metrics)
    }

    public func reset() { tokenizer.reset() }
}

private final class ReferenceParser {
    private let tokens: [PL0Token]
    private var index = 0
    private var diagnostics: [ParseDiagnostic]
    private var recoveries: [RecoveryAction] = []
    private var expectations: [ParseExpectation] = []

    init(tokens: [PL0Token], lexicalDiagnostics: [ParseDiagnostic]) {
        self.tokens = tokens
        self.diagnostics = lexicalDiagnostics
    }

    private var current: PL0Token { tokens[min(index, tokens.count - 1)] }
    private var previous: PL0Token { tokens[max(0, index - 1)] }

    func parseProgram() -> ParserOutput {
        let start = current.range.location
        let block = parseBlock()
        _ = expect(.period, message: "A PL/0 program must end with '.'")
        while current.kind != .endOfFile {
            deleteCurrent("Unexpected token after program terminator")
        }
        let root = SyntaxNode(kind: "Program", range: range(from: start), children: [block])
        return ParserOutput(root: root, diagnostics: diagnostics,
                            recoveryActions: recoveries,
                            expectations: expectations)
    }

    private func parseBlock() -> SyntaxNode {
        let start = current.range.location
        var children: [SyntaxNode] = []
        if match(.const) {
            let declarationStart = previous.range.location
            repeat {
                _ = expect(.identifier, message: "Expected a name in constant declaration")
                _ = expect(.equal, message: "Expected '=' after constant name")
                _ = expect(.number, message: "Expected a number as constant value")
            } while match(.comma)
            _ = expect(.semicolon, message: "Expected ';' after constant declarations")
            children.append(SyntaxNode(kind: "ConstDeclaration",
                                       range: range(from: declarationStart)))
        }
        if match(.varKeyword) {
            let declarationStart = previous.range.location
            repeat {
                _ = expect(.identifier, message: "Expected a name in variable declaration")
            } while match(.comma)
            _ = expect(.semicolon, message: "Expected ';' after variable declarations")
            children.append(SyntaxNode(kind: "VarDeclaration",
                                       range: range(from: declarationStart)))
        }
        while match(.procedure) {
            let procedureStart = previous.range.location
            _ = expect(.identifier, message: "Expected procedure name")
            _ = expect(.semicolon, message: "Expected ';' before procedure body")
            let body = parseBlock()
            _ = expect(.semicolon, message: "Expected ';' after procedure body")
            children.append(SyntaxNode(kind: "ProcedureDeclaration",
                                       range: range(from: procedureStart), children: [body]))
        }
        children.append(parseStatement())
        return SyntaxNode(kind: "Block", range: range(from: start), children: children)
    }

    private func parseStatement() -> SyntaxNode {
        let start = current.range.location
        switch current.kind {
        case .identifier:
            advance()
            _ = expect(.assign, message: "Expected ':=' after variable name")
            return SyntaxNode(kind: "Assignment", range: range(from: start),
                              children: [parseExpression()])
        case .call:
            advance()
            _ = expect(.identifier, message: "Expected procedure name after 'call'")
            return SyntaxNode(kind: "Call", range: range(from: start))
        case .begin:
            advance()
            var statements: [SyntaxNode] = []
            if current.kind != .end { statements.append(parseStatement()) }
            while current.kind != .end && current.kind != .endOfFile {
                if match(.semicolon) {
                    statements.append(parseStatement())
                } else if isStatementStart(current.kind) {
                    report("Expected ';' between statements", at: current.range,
                           expected: [.semicolon])
                    recoveries.append(.insert(kind: .semicolon,
                                              at: current.range.location))
                    statements.append(parseStatement())
                } else {
                    deleteCurrent("Unexpected token inside compound statement",
                                  expected: [.semicolon, .end])
                }
            }
            _ = expect(.end, message: "Expected 'end' to close compound statement")
            return SyntaxNode(kind: "BeginStatement", range: range(from: start),
                              children: statements)
        case .ifKeyword:
            advance()
            let condition = parseCondition()
            _ = expect(.then, message: "Expected 'then' after condition")
            let statement = parseStatement()
            return SyntaxNode(kind: "IfStatement", range: range(from: start),
                              children: [condition, statement])
        case .whileKeyword:
            advance()
            let condition = parseCondition()
            _ = expect(.doKeyword, message: "Expected 'do' after while condition")
            let statement = parseStatement()
            return SyntaxNode(kind: "WhileStatement", range: range(from: start),
                              children: [condition, statement])
        case .invalid:
            deleteCurrent("Invalid token in statement")
            return SyntaxNode(kind: "ErrorStatement", range: range(from: start),
                              origin: .recovered)
        case .semicolon, .end, .period, .endOfFile:
            return SyntaxNode(kind: "EmptyStatement",
                              range: SourceRange(location: start, length: 0))
        default:
            let unexpected = current
            deleteCurrent("Expected a statement", expected: statementStarts)
            if isStatementStart(current.kind) {
                return SyntaxNode(kind: "RecoveredStatement", range: range(from: start),
                                  origin: .recovered, children: [parseStatement()])
            }
            return SyntaxNode(kind: "ErrorStatement", range: unexpected.range,
                              origin: .recovered)
        }
    }

    private func parseCondition() -> SyntaxNode {
        let start = current.range.location
        if match(.odd) {
            return SyntaxNode(kind: "OddCondition", range: range(from: start),
                              children: [parseExpression()])
        }
        let left = parseExpression()
        if current.kind.isRelationalOperator { advance() }
        else {
            report("Expected a comparison operator in condition", at: current.range,
                   expected: relationalOperators)
            recoveries.append(.insert(kind: .equal, at: current.range.location))
        }
        let right = parseExpression()
        return SyntaxNode(kind: "Comparison", range: range(from: start),
                          children: [left, right])
    }

    private func parseExpression() -> SyntaxNode {
        let start = current.range.location
        _ = match(.plus) || match(.minus)
        var children = [parseTerm()]
        while current.kind == .plus || current.kind == .minus {
            advance(); children.append(parseTerm())
        }
        return SyntaxNode(kind: "Expression", range: range(from: start), children: children)
    }

    private func parseTerm() -> SyntaxNode {
        let start = current.range.location
        var children = [parseFactor()]
        while current.kind == .star || current.kind == .slash {
            advance(); children.append(parseFactor())
        }
        return SyntaxNode(kind: "Term", range: range(from: start), children: children)
    }

    private func parseFactor() -> SyntaxNode {
        let start = current.range.location
        switch current.kind {
        case .identifier:
            advance()
            return SyntaxNode(kind: "Identifier", range: range(from: start))
        case .number:
            advance()
            return SyntaxNode(kind: "Number", range: range(from: start))
        case .leftParen:
            advance()
            let expression = parseExpression()
            _ = expect(.rightParen, message: "Expected ')' after expression")
            return SyntaxNode(kind: "ParenthesizedExpression", range: range(from: start),
                              children: [expression])
        default:
            let offset = current.range.location
            let expected: [PL0TokenKind] = [.identifier, .number, .leftParen]
            if isExpressionFollower(current.kind) {
                report("Expected identifier, number, or parenthesized expression",
                       at: current.range, expected: expected)
                recoveries.append(.insert(kind: .identifier, at: offset))
            } else {
                deleteCurrent("Unexpected token in expression", expected: expected)
                if [.identifier, .number, .leftParen].contains(current.kind) {
                    return SyntaxNode(kind: "RecoveredFactor", range: range(from: offset),
                                      origin: .recovered, children: [parseFactor()])
                }
            }
            return SyntaxNode(kind: "MissingFactor",
                              range: SourceRange(location: offset, length: 0),
                              origin: .recovered)
        }
    }

    @discardableResult
    private func expect(_ kind: PL0TokenKind, message: String) -> Bool {
        if match(kind) { return true }
        report(message, at: current.range, expected: [kind])
        recoveries.append(.insert(kind: kind, at: current.range.location))
        return false
    }

    private func match(_ kind: PL0TokenKind) -> Bool {
        guard current.kind == kind else { return false }
        advance()
        return true
    }

    private func advance() {
        if current.kind != .endOfFile { index += 1 }
    }

    private func deleteCurrent(_ message: String,
                               expected: [PL0TokenKind] = []) {
        guard current.kind != .endOfFile else { return }
        let token = current
        report(message, at: token.range, expected: expected)
        recoveries.append(.delete(token: token))
        advance()
    }

    private func report(_ message: String, at range: SourceRange,
                        expected: [PL0TokenKind] = []) {
        diagnostics.append(ParseDiagnostic(severity: .error, message: message,
                                           range: range, expected: expected))
        if !expected.isEmpty {
            let expectation = ParseExpectation(offset: range.location, kinds: expected)
            if !expectations.contains(expectation) { expectations.append(expectation) }
        }
    }

    private func range(from start: Int) -> SourceRange {
        let end = index > 0 ? previous.range.end : start
        return SourceRange(location: start, length: max(0, end - start))
    }

    private func isStatementStart(_ kind: PL0TokenKind) -> Bool {
        statementStarts.contains(kind)
    }

    private var statementStarts: [PL0TokenKind] {
        [.identifier, .call, .begin, .ifKeyword, .whileKeyword]
    }

    private var relationalOperators: [PL0TokenKind] {
        [.equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual]
    }

    private func isExpressionFollower(_ kind: PL0TokenKind) -> Bool {
        [.plus, .minus, .star, .slash, .rightParen, .semicolon, .then,
         .doKeyword, .end, .period, .endOfFile].contains(kind)
    }
}
