import PL0Language
import SwiftUI

/// Exposes the reference parser rather than hiding it behind highlighting:
/// diagnostics, recovery choices, token stream, CST and timing are all visible.
@MainActor
struct PL0WorkbenchPane: View {
    let revision: UInt64
    let edit: SourceEdit?
    let source: () -> String

    @State private var result: ParseResult?
    @State private var selectedView = WorkbenchView.diagnostics
    @State private var session = PL0LanguageSession()

    private enum WorkbenchView: String, CaseIterable, Identifiable {
        case diagnostics = "Problems"
        case tokens = "Tokens"
        case syntaxTree = "CST"
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PL/0 · \(result?.parser.displayName ?? "Reference LL")")
                    .font(.headline)
                Spacer()
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
                    }
                    if !result.recoveryActions.isEmpty {
                        Divider()
                        Text("Recovery trace").font(.headline)
                        ForEach(Array(result.recoveryActions.enumerated()), id: \.offset) {
                            _, action in
                            Text(action.summary).font(.caption.monospaced())
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .tokens:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(result.tokens) { token in
                        Text("\(token.location.line):\(token.location.column)  \(token.kind.rawValue)  \(quoted(token.lexeme))")
                            .font(.caption.monospaced())
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .syntaxTree:
            ScrollView([.horizontal, .vertical]) {
                Text(result.root.outline())
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
