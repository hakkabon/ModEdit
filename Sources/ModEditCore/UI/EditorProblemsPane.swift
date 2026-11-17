import IncrementalParsing
import SwiftUI

@MainActor
struct EditorProblemsPane: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Problems").font(.headline)
                Spacer()
                if model.format.id == "pl0" {
                    if model.isBuilding {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Building")
                    } else if let result = model.buildResult {
                        Text(result.succeeded ? "Build succeeded" : "Build failed")
                            .foregroundStyle(.secondary)
                    }
                    Button("Build") { Task { await model.buildPL0() } }
                        .disabled(model.isBuilding)
                }
                Button {
                    model.showProblems = false
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Hide Problems")
                .help("Hide Problems")
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let analysis = model.languageAnalysis {
                        let fixes = Dictionary(grouping: analysis.recoveryEdits, by: \.diagnosticID)
                        ForEach(Array(analysis.diagnostics.enumerated()), id: \.offset) { _, problem in
                            row(problem, source: nil) {
                                ForEach(Array((fixes[problem.id] ?? []).enumerated()), id: \.offset) { _, fix in
                                    if let replacement = model.suggestedReplacement(for: fix.action) {
                                        let position = model.lineAndColumn(at: fix.range.location)
                                        Button(replacement.isEmpty ? "Fix · Delete" : "Fix · Use ‘\(replacement)’") {
                                            model.applySuggestedFix(fix, revision: analysis.revision.rawValue)
                                        }
                                        .controlSize(.small)
                                        .help("Apply repair at \(position.line):\(position.column)")
                                    }
                                }
                            }
                        }
                    }
                    if let build = model.buildResult {
                        ForEach(Array(build.diagnostics.enumerated()), id: \.offset) { _, problem in
                            row(problem, source: "Build") { EmptyView() }
                        }
                    }
                    if model.problemCount == 0 {
                        Text(model.languageAnalysis == nil ? "Checking source…" : "No problems")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 12))
    }

    private func row<Actions: View>(
        _ problem: LanguageProviderDiagnostic,
        source: String?,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        let position = model.lineAndColumn(at: problem.range.location)
        let severity: (title: String, icon: String, color: Color) = switch problem.severity {
        case .error: ("Error", "xmark.circle.fill", .red)
        case .warning: ("Warning", "exclamationmark.triangle.fill", .orange)
        case .information: ("Information", "info.circle", .secondary)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                model.revealSourceRange(problem.range)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: severity.icon).foregroundStyle(severity.color)
                        .accessibilityLabel(severity.title)
                    Text("\(position.line):\(position.column)")
                        .monospacedDigit().foregroundStyle(.secondary)
                    if let source { Text(source).foregroundStyle(.secondary) }
                    Text(problem.message)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reveal source location")
            actions()
        }
    }
}
