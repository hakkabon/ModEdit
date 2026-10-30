import Foundation

public enum PL0Opcode: String, Sendable {
    case push, load, store, call, allocate, jump, jumpIfFalse
    case negate, add, subtract, multiply, divide, odd
    case equal, notEqual, less, lessEqual, greater, greaterEqual
    case `return`, halt
}

public struct PL0Instruction: Sendable, Equatable, Identifiable {
    public let id: Int
    public let opcode: PL0Opcode
    public let operand: Int
    public let secondaryOperand: Int
    public let range: SourceRange

    public init(id: Int, opcode: PL0Opcode, operand: Int = 0,
                secondaryOperand: Int = 0, range: SourceRange = .zero) {
        self.id = id
        self.opcode = opcode
        self.operand = operand
        self.secondaryOperand = secondaryOperand
        self.range = range
    }

    public var listing: String {
        let arguments = switch opcode {
        case .push, .allocate, .jump, .jumpIfFalse: " \(operand)"
        case .load, .store, .call: " \(operand), \(secondaryOperand)"
        default: ""
        }
        return String(format: "%04d  %@%@", id, opcode.rawValue, arguments)
    }
}

public struct PL0Global: Sendable, Equatable {
    public let name: String
    public let slot: Int

    public init(name: String, slot: Int) {
        self.name = name
        self.slot = slot
    }
}

public struct PL0Program: Sendable, Equatable {
    public let instructions: [PL0Instruction]
    public let globals: [PL0Global]

    public init(instructions: [PL0Instruction], globals: [PL0Global]) {
        self.instructions = instructions
        self.globals = globals
    }
}

public struct PL0RuntimeValue: Sendable, Equatable, Identifiable {
    public let name: String
    public let value: Int
    public var id: String { name }
}

public struct PL0ExecutionResult: Sendable, Equatable {
    public let globals: [PL0RuntimeValue]
    public let executedInstructionCount: Int
    public let maximumStackDepth: Int
}

public enum PL0CompilationError: Error, Sendable, Equatable, CustomStringConvertible {
    case syntax([ParseDiagnostic])
    case semantic(message: String, range: SourceRange)

    public var description: String {
        switch self {
        case let .syntax(diagnostics):
            diagnostics.first?.message ?? "PL/0 syntax error"
        case let .semantic(message, _): message
        }
    }
}

public enum PL0RuntimeError: Error, Sendable, Equatable, CustomStringConvertible {
    case instructionLimitExceeded(Int)
    case divisionByZero(Int)
    case arithmeticOverflow(Int)
    case stackUnderflow(Int)
    case invalidInstructionPointer(Int)
    case invalidLexicalAddress(Int)

    public var description: String {
        switch self {
        case let .instructionLimitExceeded(limit):
            "Execution stopped after the \(limit)-instruction safety limit"
        case let .divisionByZero(pc): "Division by zero at instruction \(pc)"
        case let .arithmeticOverflow(pc): "Integer overflow at instruction \(pc)"
        case let .stackUnderflow(pc): "Stack underflow at instruction \(pc)"
        case let .invalidInstructionPointer(pc): "Invalid instruction address \(pc)"
        case let .invalidLexicalAddress(pc): "Invalid lexical address at instruction \(pc)"
        }
    }
}

/// Grammar-directed compiler for the controlled PL/0 language.
public struct PL0Compiler: Sendable {
    public init() {}

    public func compile(_ snapshot: SourceSnapshot) throws -> PL0Program {
        let parsed = PL0Frontend().parse(snapshot)
        guard parsed.diagnostics.isEmpty else {
            throw PL0CompilationError.syntax(parsed.diagnostics)
        }
        let compiler = Compiler(tokens: parsed.tokens)
        return try compiler.compileProgram()
    }
}

/// Bounded integer VM. The explicit instruction limit makes accidental or
/// deliberate infinite loops safe to run from the editor.
public struct PL0VirtualMachine: Sendable {
    public let instructionLimit: Int

    public init(instructionLimit: Int = 100_000) {
        self.instructionLimit = max(1, instructionLimit)
    }

    public func run(_ program: PL0Program) throws -> PL0ExecutionResult {
        struct Frame {
            var variables: [Int] = []
            let staticParent: Int?
            let returnPC: Int?
        }

        var frames = [Frame(staticParent: nil, returnPC: nil)]
        var values: [Int] = []
        var pc = 0
        var steps = 0
        var maximumStackDepth = 0

        func lexicalFrame(from start: Int, depth: Int) -> Int? {
            var frame = start
            for _ in 0..<depth {
                guard let parent = frames[frame].staticParent else { return nil }
                frame = parent
            }
            return frame
        }
        func pop(_ instructionPC: Int) throws -> Int {
            guard let value = values.popLast() else {
                throw PL0RuntimeError.stackUnderflow(instructionPC)
            }
            return value
        }

        execution: while true {
            guard steps < instructionLimit else {
                throw PL0RuntimeError.instructionLimitExceeded(instructionLimit)
            }
            guard program.instructions.indices.contains(pc) else {
                throw PL0RuntimeError.invalidInstructionPointer(pc)
            }
            let instruction = program.instructions[pc]
            let instructionPC = pc
            pc += 1
            steps += 1

            switch instruction.opcode {
            case .push:
                values.append(instruction.operand)
            case .allocate:
                frames[frames.count - 1].variables = Array(
                    repeating: 0, count: instruction.operand)
            case .load, .store:
                guard let frame = lexicalFrame(from: frames.count - 1,
                                               depth: instruction.operand),
                      frames[frame].variables.indices.contains(instruction.secondaryOperand)
                else { throw PL0RuntimeError.invalidLexicalAddress(instructionPC) }
                if instruction.opcode == .load {
                    values.append(frames[frame].variables[instruction.secondaryOperand])
                } else {
                    frames[frame].variables[instruction.secondaryOperand] = try pop(instructionPC)
                }
            case .call:
                guard let parent = lexicalFrame(from: frames.count - 1,
                                                depth: instruction.operand)
                else { throw PL0RuntimeError.invalidLexicalAddress(instructionPC) }
                frames.append(Frame(staticParent: parent, returnPC: pc))
                pc = instruction.secondaryOperand
            case .return:
                guard frames.count > 1, let returnPC = frames.last?.returnPC else {
                    throw PL0RuntimeError.invalidLexicalAddress(instructionPC)
                }
                frames.removeLast()
                pc = returnPC
            case .jump:
                pc = instruction.operand
            case .jumpIfFalse:
                if try pop(instructionPC) == 0 { pc = instruction.operand }
            case .negate:
                let result = 0.subtractingReportingOverflow(try pop(instructionPC))
                guard !result.overflow else {
                    throw PL0RuntimeError.arithmeticOverflow(instructionPC)
                }
                values.append(result.partialValue)
            case .add, .subtract, .multiply, .divide,
                 .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual:
                let rhs = try pop(instructionPC)
                let lhs = try pop(instructionPC)
                let value: Int
                switch instruction.opcode {
                case .add:
                    let result = lhs.addingReportingOverflow(rhs)
                    guard !result.overflow else {
                        throw PL0RuntimeError.arithmeticOverflow(instructionPC)
                    }
                    value = result.partialValue
                case .subtract:
                    let result = lhs.subtractingReportingOverflow(rhs)
                    guard !result.overflow else {
                        throw PL0RuntimeError.arithmeticOverflow(instructionPC)
                    }
                    value = result.partialValue
                case .multiply:
                    let result = lhs.multipliedReportingOverflow(by: rhs)
                    guard !result.overflow else {
                        throw PL0RuntimeError.arithmeticOverflow(instructionPC)
                    }
                    value = result.partialValue
                case .divide:
                    guard rhs != 0 else { throw PL0RuntimeError.divisionByZero(instructionPC) }
                    guard !(lhs == Int.min && rhs == -1) else {
                        throw PL0RuntimeError.arithmeticOverflow(instructionPC)
                    }
                    value = lhs / rhs
                case .equal: value = lhs == rhs ? 1 : 0
                case .notEqual: value = lhs != rhs ? 1 : 0
                case .less: value = lhs < rhs ? 1 : 0
                case .lessEqual: value = lhs <= rhs ? 1 : 0
                case .greater: value = lhs > rhs ? 1 : 0
                case .greaterEqual: value = lhs >= rhs ? 1 : 0
                default: fatalError("unreachable opcode")
                }
                values.append(value)
            case .odd:
                values.append((try pop(instructionPC)) % 2 == 0 ? 0 : 1)
            case .halt:
                break execution
            }
            maximumStackDepth = max(maximumStackDepth, values.count)
        }

        let globals = program.globals.map { global in
            PL0RuntimeValue(name: global.name,
                            value: frames[0].variables[global.slot])
        }
        return PL0ExecutionResult(globals: globals,
                                  executedInstructionCount: steps,
                                  maximumStackDepth: maximumStackDepth)
    }
}

private final class Compiler {
    private enum Symbol {
        case constant(Int)
        case variable(level: Int, slot: Int)
        case procedure(level: Int, address: Int)
    }

    private struct Scope {
        let level: Int
        var symbols: [String: Symbol] = [:]
        var variables: [PL0Global] = []
    }

    private let tokens: [PL0Token]
    private var index = 0
    private var instructions: [PL0Instruction] = []
    private var scopes = [Scope(level: 0)]

    init(tokens: [PL0Token]) { self.tokens = tokens }

    private var current: PL0Token { tokens[min(index, tokens.count - 1)] }
    private var level: Int { scopes.count - 1 }

    func compileProgram() throws -> PL0Program {
        try compileBlock(isMain: true)
        try expect(.period)
        return PL0Program(instructions: instructions, globals: scopes[0].variables)
    }

    private func compileBlock(isMain: Bool) throws {
        let jump = emit(.jump, operand: 0, at: current.range)

        if match(.const) {
            repeat {
                let name = try identifier()
                try expect(.equal)
                let valueToken = current
                try expect(.number)
                guard let value = Int(valueToken.lexeme) else {
                    throw semantic("Integer literal is outside the VM range", at: valueToken.range)
                }
                try define(name.lexeme, symbol: .constant(value), at: name.range)
            } while match(.comma)
            try expect(.semicolon)
        }

        if match(.varKeyword) {
            repeat {
                let name = try identifier()
                let slot = scopes[scopes.count - 1].variables.count
                scopes[scopes.count - 1].variables.append(
                    PL0Global(name: name.lexeme, slot: slot))
                try define(name.lexeme, symbol: .variable(level: level, slot: slot),
                           at: name.range)
            } while match(.comma)
            try expect(.semicolon)
        }

        while match(.procedure) {
            let name = try identifier()
            try expect(.semicolon)
            let address = instructions.count
            try define(name.lexeme, symbol: .procedure(level: level, address: address),
                       at: name.range)
            scopes.append(Scope(level: level + 1))
            try compileBlock(isMain: false)
            scopes.removeLast()
            try expect(.semicolon)
        }

        patch(jump, operand: instructions.count)
        emit(.allocate, operand: scopes[scopes.count - 1].variables.count,
             at: current.range)
        try compileStatement()
        emit(isMain ? .halt : .return, at: current.range)
    }

    private func compileStatement() throws {
        switch current.kind {
        case .identifier:
            let name = current
            advance()
            try expect(.assign)
            try compileExpression()
            guard case let .variable(declarationLevel, slot)? = resolve(name.lexeme) else {
                throw semantic("'\(name.lexeme)' is not a variable", at: name.range)
            }
            emit(.store, operand: level - declarationLevel,
                 secondary: slot, at: name.range)
        case .call:
            advance()
            let name = try identifier()
            guard case let .procedure(declarationLevel, address)? = resolve(name.lexeme) else {
                throw semantic("Unknown procedure '\(name.lexeme)'", at: name.range)
            }
            emit(.call, operand: level - declarationLevel,
                 secondary: address, at: name.range)
        case .begin:
            advance()
            if current.kind != .end { try compileStatement() }
            while match(.semicolon) { try compileStatement() }
            try expect(.end)
        case .ifKeyword:
            advance()
            try compileCondition()
            try expect(.then)
            let branch = emit(.jumpIfFalse, operand: 0, at: current.range)
            try compileStatement()
            patch(branch, operand: instructions.count)
        case .whileKeyword:
            advance()
            let loop = instructions.count
            try compileCondition()
            try expect(.doKeyword)
            let exit = emit(.jumpIfFalse, operand: 0, at: current.range)
            try compileStatement()
            emit(.jump, operand: loop, at: current.range)
            patch(exit, operand: instructions.count)
        case .semicolon, .end, .period, .endOfFile:
            break
        default:
            throw semantic("Expected a statement", at: current.range)
        }
    }

    private func compileCondition() throws {
        if current.kind == .odd {
            let odd = current
            advance()
            try compileExpression()
            emit(.odd, at: odd.range)
            return
        }
        try compileExpression()
        let relation = current
        guard relation.kind.isRelationalOperator else {
            throw semantic("Expected a comparison operator", at: relation.range)
        }
        advance()
        try compileExpression()
        let opcode: PL0Opcode = switch relation.kind {
        case .equal: .equal
        case .notEqual: .notEqual
        case .less: .less
        case .lessEqual: .lessEqual
        case .greater: .greater
        case .greaterEqual: .greaterEqual
        default: fatalError("unreachable relation")
        }
        emit(opcode, at: relation.range)
    }

    private func compileExpression() throws {
        let unaryToken = current
        let unary = unaryToken.kind
        if unary == .plus || unary == .minus { advance() }
        try compileTerm()
        if unary == .minus { emit(.negate, at: unaryToken.range) }
        while current.kind == .plus || current.kind == .minus {
            let operation = current
            advance()
            try compileTerm()
            emit(operation.kind == .plus ? .add : .subtract, at: operation.range)
        }
    }

    private func compileTerm() throws {
        try compileFactor()
        while current.kind == .star || current.kind == .slash {
            let operation = current
            advance()
            try compileFactor()
            emit(operation.kind == .star ? .multiply : .divide, at: operation.range)
        }
    }

    private func compileFactor() throws {
        let token = current
        switch token.kind {
        case .identifier:
            advance()
            guard let symbol = resolve(token.lexeme) else {
                throw semantic("Unknown identifier '\(token.lexeme)'", at: token.range)
            }
            switch symbol {
            case let .constant(value): emit(.push, operand: value, at: token.range)
            case let .variable(declarationLevel, slot):
                emit(.load, operand: level - declarationLevel,
                     secondary: slot, at: token.range)
            case .procedure:
                throw semantic("Procedure '\(token.lexeme)' is not a value", at: token.range)
            }
        case .number:
            advance()
            guard let value = Int(token.lexeme) else {
                throw semantic("Integer literal is outside the VM range", at: token.range)
            }
            emit(.push, operand: value, at: token.range)
        case .leftParen:
            advance()
            try compileExpression()
            try expect(.rightParen)
        default:
            throw semantic("Expected an expression value", at: token.range)
        }
    }

    private func resolve(_ name: String) -> Symbol? {
        let key = name.lowercased()
        for scope in scopes.reversed() {
            if let symbol = scope.symbols[key] { return symbol }
        }
        return nil
    }

    private func define(_ name: String, symbol: Symbol,
                        at range: SourceRange) throws {
        let key = name.lowercased()
        guard scopes[scopes.count - 1].symbols[key] == nil else {
            throw semantic("Duplicate declaration of '\(name)'", at: range)
        }
        scopes[scopes.count - 1].symbols[key] = symbol
    }

    private func identifier() throws -> PL0Token {
        let token = current
        try expect(.identifier)
        return token
    }

    private func expect(_ kind: PL0TokenKind) throws {
        guard current.kind == kind else {
            throw semantic("Expected \(kind.displayName)", at: current.range)
        }
        advance()
    }

    private func match(_ kind: PL0TokenKind) -> Bool {
        guard current.kind == kind else { return false }
        advance()
        return true
    }

    private func advance() {
        if current.kind != .endOfFile { index += 1 }
    }

    @discardableResult
    private func emit(_ opcode: PL0Opcode, operand: Int = 0,
                      secondary: Int = 0, at range: SourceRange) -> Int {
        let address = instructions.count
        instructions.append(PL0Instruction(id: address, opcode: opcode,
                                           operand: operand,
                                           secondaryOperand: secondary,
                                           range: range))
        return address
    }

    private func patch(_ address: Int, operand: Int) {
        let old = instructions[address]
        instructions[address] = PL0Instruction(
            id: old.id, opcode: old.opcode, operand: operand,
            secondaryOperand: old.secondaryOperand, range: old.range)
    }

    private func semantic(_ message: String, at range: SourceRange) -> PL0CompilationError {
        .semantic(message: message, range: range)
    }
}
