import PL0Language
import SwiftUI

/// Exposes the reference parser rather than hiding it behind highlighting:
/// diagnostics, recovery choices, token stream, CST and timing are all visible.
@MainActor
struct PL0WorkbenchPane: View {
    let revision: UInt64
    let edit: SourceEdit?
    let source: () -> String
    let publish: (ParseResult) -> Void
    let reveal: (SourceRange) -> Void
    let replaceSource: (String) -> Void

    @State private var result: ParseResult?
    @State private var selectedView = WorkbenchView.diagnostics
    @State private var session = PL0LanguageSession()
    @State private var runtime = RuntimeState.idle

    private enum WorkbenchView: String, CaseIterable, Identifiable {
        case diagnostics = "Problems"
        case recovery = "Recovery"
        case tokens = "Tokens"
        case syntaxTree = "CST"
        case runtime = "Run"
        var id: Self { self }
    }

    private enum RuntimeState: Sendable {
        case idle
        case running
        case success(PL0Program, PL0ExecutionResult)
        case failure(String)
    }

    private enum FormatOutcome: Sendable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PL/0 · \(result?.parser.displayName ?? "Reference LL")")
                    .font(.headline)
                Spacer()
                Button("Format", action: formatDocument)
                    .controlSize(.small)
                Button("Run", action: runProgram)
                    .controlSize(.small)
                    .disabled(isRunning)
                if let result {
                    Text(summary(result))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)

            Picker("Workbench view", selection: $selectedView) {
                ForEach(WorkbenchView.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()
            if let result { content(for: result) }
            else {
                ProgressView("Parsing…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 300, idealWidth: 390)
        .task(id: revision) { await refresh() }
        .onChange(of: revision) { _ in runtime = .idle }
    }

    @ViewBuilder
    private func content(for result: ParseResult) -> some View {
        switch selectedView {
        case .diagnostics:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if result.diagnostics.isEmpty {
                        Label("No syntax problems", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    ForEach(result.diagnostics) { diagnostic in
                        Button { reveal(diagnostic.range) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(diagnostic.message,
                                      systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text("UTF-16 range \(diagnostic.range.location)..<\(diagnostic.range.end)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                if !diagnostic.expected.isEmpty {
                                    Text("expected: \(diagnostic.expected.map(\.displayName).joined(separator: ", "))")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .tokens:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(result.tokens) { token in
                        Button { reveal(token.range) } label: {
                            Text("\(token.location.line):\(token.location.column)  \(token.kind.rawValue)  \(quoted(token.lexeme))")
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .recovery:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if result.recovery.isClean {
                        Label("No parser recovery", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Cost \(result.recovery.totalCost) · \(result.recovery.insertionCount) inserted · \(result.recovery.deletionCount) skipped")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        ForEach(result.recovery.events) { event in
                            Button { reveal(event.action.range) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(event.sequence + 1). \(event.action.summary)")
                                        .font(.caption.monospaced())
                                    if !event.expected.isEmpty {
                                        Text("expected: \(event.expected.map(\.displayName).joined(separator: ", "))")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("cost \(event.cost) · \(event.diagnosticIDs.count) linked problem(s)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .syntaxTree:
            ScrollView([.horizontal, .vertical]) {
                Text(result.syntaxTree.outline())
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .runtime:
            runtimeContent
        }
    }

    @ViewBuilder
    private var runtimeContent: some View {
        switch runtime {
        case .idle:
            VStack(spacing: 8) {
                Label("Program not run", systemImage: "play.circle")
                    .font(.headline)
                Text("Compile and execute the current PL/0 source.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .running:
            ProgressView("Compiling and running…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failure(message):
            ScrollView {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case let .success(program, execution):
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text("Completed · \(execution.executedInstructionCount) instructions · max stack \(execution.maximumStackDepth)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("Globals").font(.headline)
                    if execution.globals.isEmpty {
                        Text("No global variables").foregroundStyle(.secondary)
                    } else {
                        ForEach(execution.globals) { value in
                            Text("\(value.name) = \(value.value)")
                                .font(.caption.monospaced())
                        }
                    }
                    Divider()
                    Text("Bytecode").font(.headline)
                    ForEach(program.instructions) { instruction in
                        Button { reveal(instruction.range) } label: {
                            Text(instruction.listing)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
    }

    private func refresh() async {
        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        guard !Task.isCancelled else { return }
        let snapshot = SourceSnapshot(version: revision, text: source(), edit: edit)
        let parsed = await session.parse(snapshot)
        guard !Task.isCancelled, parsed.version == revision else { return }
        result = parsed
        publish(parsed)
    }

    private var isRunning: Bool {
        if case .running = runtime { true } else { false }
    }

    private func formatDocument() {
        let requestedRevision = revision
        let text = source()
        Task {
            let outcome = await Task.detached {
                do { return FormatOutcome.success(try PL0Formatter().format(text)) }
                catch { return FormatOutcome.failure(String(describing: error)) }
            }.value
            guard requestedRevision == revision else { return }
            switch outcome {
            case let .success(formatted): replaceSource(formatted)
            case let .failure(message):
                runtime = .failure("Format failed: \(message)")
                selectedView = .runtime
            }
        }
    }

    private func runProgram() {
        let requestedRevision = revision
        let snapshot = SourceSnapshot(version: requestedRevision, text: source())
        runtime = .running
        selectedView = .runtime
        Task {
            let completed = await Task.detached { () -> RuntimeState in
                do {
                    let program = try PL0Compiler().compile(snapshot)
                    let execution = try PL0VirtualMachine().run(program)
                    return .success(program, execution)
                } catch {
                    return .failure(String(describing: error))
                }
            }.value
            guard requestedRevision == revision else { return }
            runtime = completed
        }
    }

    private func elapsed(_ result: ParseResult) -> String {
        let total = result.metrics.lexingNanoseconds + result.metrics.parsingNanoseconds
        return String(format: "%.3f ms", Double(total) / 1_000_000)
    }

    private func summary(_ result: ParseResult) -> String {
        let lex = result.metrics.incrementalLexing
        let parse = result.metrics.incrementalParsing
        let lexReuse = lex.incremental
            ? " · scan \(lex.scannedUTF16Length) · lex reuse \(lex.reusedPrefixTokenCount + lex.reusedSuffixTokenCount)"
            : " · full lex"
        let parseReuse = parse.incremental
            ? " · parse reuse \(parse.reusedNodeCount)n/\(parse.reusedTokenCount)t"
            : " · full parse"
        return "v\(result.version) · \(result.metrics.tokenCount) tokens\(lexReuse)\(parseReuse) · \(elapsed(result))"
    }

    private func quoted(_ text: String) -> String {
        text.isEmpty ? "<eof>" : "\"\(text.replacingOccurrences(of: "\n", with: "\\n"))\""
    }
}
