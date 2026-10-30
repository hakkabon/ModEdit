import Foundation
import Testing
@testable import PL0Language

@Suite("PL/0 formatter and VM")
struct FormatterVMTests {
    @Test func formatterIsIdempotentAndPreservesComments() throws {
        let source = "const limit=3; // maximum\nvar x,square; procedure calc;begin /* body */ square:=x*x end;begin x:=1;while x<=limit do begin call calc;x:=x+1 end end."
        let formatter = PL0Formatter(indentationWidth: 2)

        let formatted = try formatter.format(source)

        #expect(formatted == (try formatter.format(formatted)))
        #expect(formatted.contains("// maximum"))
        #expect(formatted.contains("/* body */"))
        #expect(formatted.contains("square := x * x"))
        #expect(formatted.hasSuffix("\n"))
        #expect(PL0Frontend().parse(SourceSnapshot(version: 1, text: formatted))
            .diagnostics.isEmpty)
        #expect(try formatter.format("var x; x:=-1+2.")
            .contains("x := -1 + 2"))
    }

    @Test func formatterRefusesRecoveredSyntax() {
        #expect(throws: PL0FormatterError.self) {
            _ = try PL0Formatter().format("begin x := end.")
        }
    }

    @Test func arithmeticUsesPL0Precedence() throws {
        let result = try execute("var x; x := 2 + 3 * 4.")
        #expect(value("x", in: result) == 14)
    }

    @Test func loopsConditionsAndOddExecute() throws {
        let result = try execute("""
            var x, sum;
            begin
              x := 1;
              sum := 0;
              while x <= 5 do
              begin
                if odd x then sum := sum + x;
                x := x + 1
              end
            end.
            """)
        #expect(value("x", in: result) == 6)
        #expect(value("sum", in: result) == 9)
    }

    @Test func proceduresUpdateGlobalVariables() throws {
        let source = try #require(String(
            data: Data(contentsOf: exampleURL()), encoding: .utf8))
        let result = try execute(source)

        #expect(value("x", in: result) == 11)
        #expect(value("square", in: result) == 100)
    }

    @Test func nestedProcedureUsesItsLexicalParentFrame() throws {
        let result = try execute("""
            var x;
            procedure outer;
              var y;
              procedure inner;
              begin y := y + 1; x := x + y end;
            begin y := 2; call inner end;
            begin x := 1; call outer end.
            """)
        #expect(value("x", in: result) == 4)
    }

    @Test func recursiveProcedureExecutes() throws {
        let result = try execute("""
            var n, result;
            procedure factorial;
            begin
              if n > 1 then
              begin result := result * n; n := n - 1; call factorial end
            end;
            begin n := 5; result := 1; call factorial end.
            """)
        #expect(value("result", in: result) == 120)
        #expect(value("n", in: result) == 1)
    }

    @Test func semanticErrorsIdentifyUnknownNames() {
        #expect(throws: PL0CompilationError.self) {
            _ = try PL0Compiler().compile(SourceSnapshot(version: 1, text: "x := 1."))
        }
    }

    @Test func divisionByZeroIsARuntimeError() throws {
        let program = try compile("var x; x := 1 / 0.")
        #expect(throws: PL0RuntimeError.self) {
            _ = try PL0VirtualMachine().run(program)
        }
    }

    @Test func instructionLimitStopsInfinitePrograms() throws {
        let program = try compile("var x; while x = 0 do x := 0.")
        #expect(throws: PL0RuntimeError.self) {
            _ = try PL0VirtualMachine(instructionLimit: 50).run(program)
        }
    }

    @Test func integerOverflowIsARuntimeError() throws {
        let source = "var x; x := \(Int.max) + 1."
        let program = try compile(source)
        #expect(throws: PL0RuntimeError.self) {
            _ = try PL0VirtualMachine().run(program)
        }
    }

    private func compile(_ source: String) throws -> PL0Program {
        try PL0Compiler().compile(SourceSnapshot(version: 1, text: source))
    }

    private func execute(_ source: String) throws -> PL0ExecutionResult {
        try PL0VirtualMachine().run(compile(source))
    }

    private func value(_ name: String, in result: PL0ExecutionResult) -> Int? {
        result.globals.first { $0.name == name }?.value
    }

    private func exampleURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/squares.pl0")
    }
}
