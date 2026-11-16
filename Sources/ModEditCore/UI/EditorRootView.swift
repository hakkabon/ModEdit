import SwiftUI

/// One editor window: source editor on the left, optional live preview on the right.
@MainActor
struct EditorRootView: View {
    /// The window controller owns the model, so this is `@ObservedObject`, not
    /// `@StateObject`: recreating the view must not create a second model.
    @ObservedObject var model: EditorModel

    var body: some View {
        let renderer = model.format.makePreviewRenderer()
        VStack(spacing: 0) {
            HSplitView {
                EditorTextView(model: model).frame(minWidth: 300)
                if model.showPreview, let renderer {
                    PreviewPane(renderer: renderer,
                                revision: model.textRevision,
                                source: { model.previewSnapshot(upTo: PreviewPane.maximumSourceLength) })
                        .frame(minWidth: 300)
                }
                if model.showWorkbench, model.format.id == "pl0" {
                    PL0WorkbenchPane(revision: model.textRevision,
                                     edit: model.lastSourceEdit,
                                     source: { model.textSnapshot() },
                                     reveal: model.revealSourceRange,
                                     replaceSource: model.requestSourceReplacement)
                }
            }
            EditorStatusBar(model: model, formatID: formatID)
        }
        .task(id: "\(model.format.id):\(model.textRevision)") {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            await model.refreshLanguageDiagnostics()
        }
    }

    private var formatID: Binding<String> {
        Binding(
            get: { model.format.id },
            set: { id in
                if let provider = model.registry.provider(withID: id) {
                    model.setFormat(provider.documentFormat)
                }
            })
    }
}

@MainActor
private struct EditorStatusBar: View {
    @ObservedObject var model: EditorModel
    let formatID: Binding<String>
    @State private var completions: [EditorCompletionSuggestion] = []
    @State private var showsCompletions = false
    @State private var showsMissingDefinition = false

    var body: some View {
        HStack(spacing: 14) {
            Text("\(model.cursorLine):\(model.cursorColumn)")
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .leading)
                .accessibilityLabel("Cursor line \(model.cursorLine), column \(model.cursorColumn)")

            Picker("Text type", selection: formatID) {
                ForEach(model.registry.allProviders, id: \.descriptor.id) { provider in
                    Text(provider.descriptor.displayName).tag(provider.descriptor.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Text("Tab Size: \(model.tabSize)")
                .foregroundStyle(.secondary)

            if let visualization = model.pl0Visualization,
               visualization.version == model.textRevision {
                Menu("\(visualization.problemCount) problems") {
                    ForEach(visualization.annotations) { annotation in
                        let position = model.lineAndColumn(at: annotation.range.location)
                        Button("\(position.line):\(position.column) \(annotation.message)") {
                            model.revealSourceRange(annotation.range)
                        }
                    }
                    if let analysis = model.languageAnalysis {
                        ForEach(Array(analysis.recoveryEdits.enumerated()), id: \.offset) { _, fix in
                            if fix.diagnosticID != nil,
                               let replacement = model.suggestedReplacement(for: fix.action) {
                                let position = model.lineAndColumn(at: fix.action.range.location)
                                Button(replacement.isEmpty
                                       ? "Delete text at \(position.line):\(position.column)"
                                       : "Use ‘\(replacement)’ at \(position.line):\(position.column)") {
                                    model.applySuggestedFix(fix, revision: analysis.revision.rawValue)
                                }
                            }
                        }
                    }
                }
                .fixedSize()
                .disabled(visualization.problemCount == 0)
            }

            if model.supportsLanguageQueries {
                Button("Complete") {
                    Task {
                        completions = await model.completionSuggestions()
                        showsCompletions = true
                    }
                }
                .keyboardShortcut(" ", modifiers: [.control])
                .popover(isPresented: $showsCompletions) {
                    ScrollView {
                        VStack(alignment: .leading) {
                            if completions.isEmpty { Text("No completions") }
                            ForEach(completions) { suggestion in
                                Button(suggestion.item.label) {
                                    model.acceptCompletion(suggestion)
                                    showsCompletions = false
                                }
                                .help(suggestion.item.detail)
                            }
                        }
                        .padding()
                    }
                    .frame(maxHeight: 240)
                }
                Button("Go to Definition") {
                    Task { showsMissingDefinition = !(await model.goToDefinition()) }
                }
                .popover(isPresented: $showsMissingDefinition) {
                    Text("No definition at the cursor").padding()
                }
            }

            Spacer(minLength: 20)

            Text(model.isDocumentDirty ? "DOCUMENT DIRTY" : "DOCUMENT CLEAN")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(model.isDocumentDirty ? Color(red: 0.85, green: 0.20, blue: 0.10)
                                                       : Color(red: 0.38, green: 0.48, blue: 0.08),
                            in: Capsule())
                .accessibilityLabel(model.isDocumentDirty ? "Document dirty" : "Document clean")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
