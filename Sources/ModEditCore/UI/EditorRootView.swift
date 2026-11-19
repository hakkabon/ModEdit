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
                VSplitView {
                    EditorTextView(model: model).frame(minHeight: 120)
                    if model.showProblems, model.supportsProblems {
                        EditorProblemsPane(model: model)
                            .frame(minHeight: 85, idealHeight: 170)
                    }
                }
                .frame(minWidth: 300)
                if model.showPreview, model.format is DOTFormat {
                    DOTPreviewPane(model: model)
                        .frame(minWidth: 300)
                } else if model.showPreview, let renderer {
                    VSplitView {
                        PreviewPane(renderer: renderer,
                                    revision: model.textRevision,
                                    source: { model.previewSnapshot(upTo: PreviewPane.maximumSourceLength) })
                            .frame(minHeight: 120)
                        if model.format is GrammarFormat {
                            ScrollView { GrammarExamplesPane(model: model) }
                                .frame(minHeight: 180, idealHeight: 340)
                        }
                    }
                    .frame(minWidth: 300)
                }
                if model.showWorkbench, model.format.id == "pl0" {
                    PL0WorkbenchPane(revision: model.textRevision,
                                     edit: model.lastSourceEdit,
                                     model: model,
                                     source: { model.textSnapshot() },
                                     lineAndColumn: model.lineAndColumn(at:),
                                     reveal: model.revealSourceRange)
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

            if model.supportsProblems {
                Button {
                    model.showProblems.toggle()
                } label: {
                    Label("\(model.problemCount) problems",
                          systemImage: model.showProblems ? "chevron.down" : "chevron.up")
                }
                .fixedSize()
                .help(model.showProblems ? "Hide Problems" : "Show Problems")
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
