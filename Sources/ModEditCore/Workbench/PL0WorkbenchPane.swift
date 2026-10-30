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
    @State private var selectedEngine = ParserEngine.referenceLL
    @State private var session = PL0LanguageSession()
    @State private var runtime = RuntimeState.idle
    @State private var grammarWorkbenchSession: GrammarWorkbenchHotReloadSession?
    @State private var grammarWorkbenchStatus = GrammarWorkbenchHotReloadStatus.disconnected
    @State private var grammarSource = ""

    private enum WorkbenchView: String, CaseIterable, Identifiable {
        case diagnostics = "Problems"
        case recovery = "Recovery"
        case tokens = "Tokens"
        case syntaxTree = "CST"
        case comparison = "Compare"
        case trace = "Trace"
        case grammarWorkbench = "Grammar WB"
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
                Text("PL/0")
                    .font(.headline)
                Picker("Parser", selection: $selectedEngine) {
                    ForEach(ParserEngine.allCases, id: \.self) { engine in
                        Text(engine.rawValue).tag(engine)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
                Button("Format", action: formatDocument)
                    .controlSize(.small)
                Button("Run", action: runProgram)
                    .controlSize(.small)
                    .disabled(isRunning)
                if grammarWorkbenchStatus.state == .connected {
                    Circle().fill(.green).frame(width: 7, height: 7)
                        .help("Grammar Workbench connected")
                }
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
        .task(id: ParseRequest(revision: revision, engine: selectedEngine)) {
            await refresh()
        }
        .onChange(of: selectedEngine) { engine in
            result = nil
            runtime = .idle
            session = PL0LanguageSession(engine: engine)
        }
        .onChange(of: revision) { _ in runtime = .idle }
        .task { await watchGrammarWorkbench() }
        .onDisappear {
            let session = grammarWorkbenchSession
            Task { await session?.disconnect() }
        }
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
        case .comparison:
            comparisonContent(result)
        case .trace:
            traceContent(result)
        case .grammarWorkbench:
            grammarWorkbenchContent
        case .runtime:
            runtimeContent
        }
    }

    @ViewBuilder
    private var grammarWorkbenchContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label(grammarWorkbenchTitle,
                      systemImage: grammarWorkbenchStatus.state == .connected
                        ? "bolt.horizontal.circle.fill" : "bolt.slash.circle")
                    .font(.headline)
                    .foregroundStyle(grammarWorkbenchStatus.state == .connected
                                     ? Color.green : Color.secondary)
                Text(grammarWorkbenchStatus.message)
                    .font(.caption)
                    .textSelection(.enabled)
                if grammarWorkbenchStatus.state == .connected {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        GridRow { Text("Grammar revision"); Text("\(grammarWorkbenchStatus.grammarRevision)") }
                        GridRow { Text("Reloads"); Text("\(grammarWorkbenchStatus.reloadCount)") }
                        GridRow { Text("Document revision"); Text(grammarWorkbenchStatus.documentRevision.map(String.init) ?? "—") }
                        GridRow { Text("Parse status"); Text(grammarWorkbenchStatus.parseStatus ?? "—") }
                        GridRow { Text("Tokens"); Text("\(grammarWorkbenchStatus.tokenCount)") }
                        GridRow { Text("Diagnostics"); Text("\(grammarWorkbenchStatus.lexicalDiagnosticCount + grammarWorkbenchStatus.syntaxDiagnosticCount)") }
                    }
                    .font(.caption.monospacedDigit())
                    Button("Reload Now") { Task { await reloadGrammarWorkbench() } }
                        .controlSize(.small)
                } else if Self.grammarWorkbenchConfiguration == nil {
                    Text("Set MODEDIT_GRAMMAR_WORKBENCH_SERVICE to the grammar-workbench-service executable and MODEDIT_PL0_GRAMMAR to a Workbench grammar file, then reopen the document.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Divider()
                Text("Grammar replacements are compiled atomically by Grammar Workbench. A rejected file leaves the previous grammar revision active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var grammarWorkbenchTitle: String {
        switch grammarWorkbenchStatus.state {
        case .disconnected: "Grammar Workbench not configured"
        case .connecting: "Connecting to Grammar Workbench"
        case .connected: "Grammar Workbench hot reload"
        case .failed: "Grammar Workbench connection failed"
        }
    }

    private struct ParseRequest: Hashable {
        let revision: UInt64
        let engine: ParserEngine
    }

    @ViewBuilder
    private func comparisonContent(_ result: ParseResult) -> some View {
        let input = ParserInput(tokens: result.tokens, lexicalDiagnostics: [])
        let lr = LRPL0Parser().recognize(input)
        let earley = EarleyPL0Parser().recognize(input)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Grammar recognition").font(.headline)
                comparisonRow(name: "Reference LL",
                              accepted: result.diagnostics.isEmpty,
                              detail: "normalized CST and recovery oracle")
                comparisonRow(name: "Generated SLR(1)", accepted: lr.accepted,
                              detail: "\(lr.configurationCount) actions · stack \(lr.maximumFrontierSize) · consumed \(lr.consumedTokenCount)")
                comparisonRow(name: "Earley Chart", accepted: earley.accepted,
                              detail: "\(earley.configurationCount) items · chart max \(earley.maximumFrontierSize) · consumed \(earley.consumedTokenCount)")
                Divider()
                Text("Selected engine: \(result.parser.displayName)")
                    .font(.caption.monospaced())
                Text("LR and Earley perform independent recognition. Their CST and recovery output is normalized through the reference adapter so results can be compared structurally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func comparisonRow(name: String, accepted: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: accepted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(accepted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.bold())
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func traceContent(_ result: ParseResult) -> some View {
        switch result.algorithmArtifact {
        case let .lr(artifact):
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Text("LR · \(artifact.trace.count) events · reused \(artifact.reusedTokenCount) tokens")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    ForEach(artifact.trace) { event in
                        Text("\(event.id)  \(event.action.rawValue)  t\(event.tokenIndex) s\(event.state) depth \(event.stackDepth)  \(event.detail)")
                            .font(.caption.monospaced())
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        case let .earley(artifact):
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Text("Earley · \(artifact.trace.count) events · reused \(artifact.reusedChartColumnCount) columns · \(artifact.forest?.nodes.count ?? 0) forest nodes · \(artifact.forest?.packedAlternativeCount ?? 0) packed alternatives")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    ForEach(artifact.trace) { event in
                        Text("\(event.id)  \(event.action.rawValue)  chart[\(event.chartIndex)]  \(event.production)  dot \(event.dot) origin \(event.origin)")
                            .font(.caption.monospaced())
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        case nil:
            VStack(spacing: 8) {
                Label("Reference parser", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Text("Select Generated SLR(1) or Earley Chart to inspect its native trace.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        if let grammarWorkbenchSession {
            do {
                grammarWorkbenchStatus = try await grammarWorkbenchSession.updateDocument(
                    snapshot.text, revision: revision)
            } catch {
                grammarWorkbenchStatus = await grammarWorkbenchSession.status()
            }
        }
    }

    private static var grammarWorkbenchConfiguration: (service: URL, grammar: URL)? {
        let environment = ProcessInfo.processInfo.environment
        guard let service = environment["MODEDIT_GRAMMAR_WORKBENCH_SERVICE"],
              let grammar = environment["MODEDIT_PL0_GRAMMAR"],
              !service.isEmpty, !grammar.isEmpty else { return nil }
        return (URL(fileURLWithPath: service), URL(fileURLWithPath: grammar))
    }

    private func watchGrammarWorkbench() async {
        guard let configuration = Self.grammarWorkbenchConfiguration else { return }
        grammarWorkbenchStatus = GrammarWorkbenchHotReloadStatus(
            state: .connecting, message: "Launching Grammar Workbench service…")
        do {
            let transport = try GrammarWorkbenchProcessTransport(
                executableURL: configuration.service)
            let session = GrammarWorkbenchHotReloadSession(transport: transport)
            grammarWorkbenchSession = session
            grammarSource = try String(contentsOf: configuration.grammar,
                                       encoding: .utf8)
            grammarWorkbenchStatus = try await session.connect(
                grammar: grammarSource, document: source(), revision: revision)
            var modification = try modificationDate(configuration.grammar)
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(500))
                let next = try modificationDate(configuration.grammar)
                guard next != modification else { continue }
                modification = next
                await reloadGrammarWorkbench()
            }
        } catch is CancellationError {
            return
        } catch {
            grammarWorkbenchStatus = GrammarWorkbenchHotReloadStatus(
                state: .failed, message: String(describing: error))
        }
    }

    private func reloadGrammarWorkbench() async {
        guard let configuration = Self.grammarWorkbenchConfiguration,
              let grammarWorkbenchSession else { return }
        do {
            let candidate = try String(contentsOf: configuration.grammar,
                                       encoding: .utf8)
            grammarWorkbenchStatus = try await grammarWorkbenchSession.reload(
                grammar: candidate)
            grammarSource = candidate
        } catch {
            grammarWorkbenchStatus = await grammarWorkbenchSession.status()
        }
    }

    private func modificationDate(_ url: URL) throws -> Date {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return values.contentModificationDate ?? .distantPast
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
