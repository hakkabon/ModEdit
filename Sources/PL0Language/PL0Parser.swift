import Foundation

/// Parser identity is explicit so the workbench can compare engines later
/// without changing its result model.
public enum ParserEngine: String, Sendable, CaseIterable {
    case referenceLL = "Reference LL"
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
        let parsed = ReferenceParser(tokens: lexed.tokens,
                                     lexicalDiagnostics: lexed.diagnostics).parseProgram()
        let parseDuration = parseStart.duration(to: clock.now)
        return ParseResult(
            version: snapshot.version, tokens: lexed.tokens, root: parsed.root,
            diagnostics: parsed.diagnostics, recoveryActions: parsed.recoveries,
            metrics: ParseMetrics(
                sourceLength: snapshot.text.utf16.count,
                tokenCount: max(0, lexed.tokens.count - 1),
                lexingNanoseconds: lexingNanoseconds,
                parsingNanoseconds: Self.nanoseconds(parseDuration),
                recoveryCount: parsed.recoveries.count,
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
    struct Output {
        let root: SyntaxNode
        let diagnostics: [ParseDiagnostic]
        let recoveries: [RecoveryAction]
    }

    private let tokens: [PL0Token]
    private var index = 0
    private var diagnostics: [ParseDiagnostic]
    private var recoveries: [RecoveryAction] = []

    init(tokens: [PL0Token], lexicalDiagnostics: [ParseDiagnostic]) {
        self.tokens = tokens
        self.diagnostics = lexicalDiagnostics
    }

    private var current: PL0Token { tokens[min(index, tokens.count - 1)] }
    private var previous: PL0Token { tokens[max(0, index - 1)] }

    func parseProgram() -> Output {
        let start = current.range.location
        let block = parseBlock()
        _ = expect(.period, message: "A PL/0 program must end with '.'")
        while current.kind != .endOfFile {
            deleteCurrent("Unexpected token after program terminator")
        }
        let root = SyntaxNode(kind: "Program", range: range(from: start), children: [block])
        return Output(root: root, diagnostics: diagnostics, recoveries: recoveries)
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
            while match(.semicolon) { statements.append(parseStatement()) }
            while current.kind != .end && isStatementStart(current.kind) {
                report("Expected ';' between statements", at: current.range)
                recoveries.append(.insert(kind: .semicolon, at: current.range.location))
                statements.append(parseStatement())
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
        default:
            return SyntaxNode(kind: "EmptyStatement",
                              range: SourceRange(location: start, length: 0))
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
        else { _ = expect(.equal, message: "Expected a comparison operator in condition") }
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
            report("Expected identifier, number, or parenthesized expression", at: current.range)
            recoveries.append(.insert(kind: .identifier, at: offset))
            return SyntaxNode(kind: "MissingFactor",
                              range: SourceRange(location: offset, length: 0),
                              origin: .recovered)
        }
    }

    @discardableResult
    private func expect(_ kind: PL0TokenKind, message: String) -> Bool {
        if match(kind) { return true }
        report(message, at: current.range)
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

    private func deleteCurrent(_ message: String) {
        guard current.kind != .endOfFile else { return }
        let token = current
        report(message, at: token.range)
        recoveries.append(.delete(token: token))
        advance()
    }

    private func report(_ message: String, at range: SourceRange) {
        diagnostics.append(ParseDiagnostic(severity: .error, message: message, range: range))
    }

    private func range(from start: Int) -> SourceRange {
        let end = index > 0 ? previous.range.end : start
        return SourceRange(location: start, length: max(0, end - start))
    }

    private func isStatementStart(_ kind: PL0TokenKind) -> Bool {
        [.identifier, .call, .begin, .ifKeyword, .whileKeyword].contains(kind)
    }
}
