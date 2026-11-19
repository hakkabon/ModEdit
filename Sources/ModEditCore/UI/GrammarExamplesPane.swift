import AppKit
import GrammarLanguage
import IncrementalParsing
import SwiftUI

@MainActor
final class GrammarExamplesProject: ObservableObject {
    @Published var examples: [GrammarExample] = []
    private(set) var url: URL?
    private var savedData: Data?
    private var savedExamples: [GrammarExample] = []
    private lazy var session = GrammarProviderSession()
    private var revision: UInt64 = 0

    func check(source: String, corpus: GrammarExampleCorpus) async throws -> GrammarExampleReport {
        revision += 1
        return try await session.checkExamples(.init(text: source, revision: .init(revision)), corpus: corpus)
    }

    var hasUnsavedChanges: Bool { examples != savedExamples }

    func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let corpus = try GrammarExampleCorpus.decode(data)
        examples = corpus.examples
        self.url = url
        savedData = data
        savedExamples = examples
    }

    func save(to destination: URL) throws {
        let data = try GrammarExampleCorpus(examples: examples).encoded()
        if destination == url, let savedData, try Data(contentsOf: destination) != savedData {
            throw SaveFailure()
        }
        try data.write(to: destination, options: .atomic)
        url = destination
        savedData = data
        savedExamples = examples
    }

    private struct SaveFailure: LocalizedError {
        var errorDescription: String? {
            "The examples changed on disk. Open them again before saving."
        }
    }
}

@MainActor
struct GrammarExamplesPane: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var project: GrammarExamplesProject
    @State private var selected = 0
    @State private var report: GrammarExampleReport?
    @State private var checkedSource = ""
    @State private var checkedExamples: [GrammarExample] = []
    @State private var message: String?
    @State private var checkError: String?

    init(model: EditorModel) {
        self.model = model
        self.project = model.grammarExamples
    }

    private struct Request: Equatable {
        let revision: UInt64
        let examples: [GrammarExample]
    }

    private var current: Bool {
        report != nil && checkedSource == model.textSnapshot() && checkedExamples == project.examples
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Grammar examples").font(.headline)
                Spacer()
                Button("Open…", action: open)
                Button("Add") {
                    project.examples.append(.init(id: "example-\(UUID().uuidString.prefix(8))",
                                          input: "", shouldAccept: true))
                    selected = project.examples.count - 1
                }.disabled(project.examples.count >= 100)
                Button("Save…", action: save)
                    .help("Save the example inputs and expected outcomes")
                    .disabled(project.examples.isEmpty)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if project.examples.isEmpty {
                Text("Open an examples JSON file, or add an example and choose whether it should be accepted.")
                    .foregroundStyle(.secondary)
            } else {
                if let checkError {
                    Text(checkError).foregroundStyle(.orange)
                } else if current, let report {
                    Text(!report.grammarValid ? "Fix the grammar to check the examples."
                         : report.passed ? "All examples passed." : "Some examples failed.")
                        .foregroundStyle(report.passed ? Color.green : Color.orange)
                    if !report.affectedRules.isEmpty {
                        Text("Changed rules · " + report.affectedRules.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(report.diagnostics) { diagnostic in
                        Button(diagnostic.message) { model.revealSourceRange(diagnostic.range) }
                            .buttonStyle(.plain)
                    }
                } else {
                    Text("Checking examples…").foregroundStyle(.secondary)
                }
                Picker("Example", selection: $selected) {
                    ForEach(project.examples.indices, id: \.self) { index in
                        Text(project.examples[index].id).tag(index)
                    }
                }
                if project.examples.indices.contains(selected) {
                    TextField("Example name", text: $project.examples[selected].id)
                    Toggle("Should be accepted", isOn: $project.examples[selected].shouldAccept)
                    TextEditor(text: $project.examples[selected].input)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 65, maxHeight: 110)
                    if current, let result = report?.examples.first(where: { $0.id == project.examples[selected].id }) {
                        Text("\(result.passed ? "Passed" : "Failed") · \(result.status.rawValue)")
                            .foregroundStyle(result.passed ? Color.green : Color.red)
                        Text(result.message).font(.caption).textSelection(.enabled)
                        if let tree = result.tree {
                            DisclosureGroup("Parse tree") {
                                ScrollView {
                                    Text(tree).font(.caption.monospaced())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }.frame(maxHeight: 160)
                            }
                        }
                    }
                    Button("Remove Example") {
                        project.examples.remove(at: selected)
                        selected = max(0, min(selected, project.examples.count - 1))
                    }
                }
                if project.hasUnsavedChanges {
                    Text("Examples have unsaved changes.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .task(id: Request(revision: model.textRevision, examples: project.examples)) {
            guard !project.examples.isEmpty else { return }
            let source = model.textSnapshot()
            let corpus = GrammarExampleCorpus(examples: project.examples)
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                checkError = nil
                let checked = try await project.check(source: source, corpus: corpus)
                guard !Task.isCancelled, model.textSnapshot() == source, project.examples == corpus.examples else { return }
                checkedSource = source
                checkedExamples = corpus.examples
                report = checked
                message = project.url?.lastPathComponent
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { report = nil; checkError = error.localizedDescription }
            }
        }
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        do {
            try project.load(from: chosen)
            selected = 0
            message = chosen.lastPathComponent
        } catch { message = error.localizedDescription }
    }

    private func save() {
        do {
            var destination = project.url
            if destination == nil {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "Examples.json"
                guard panel.runModal() == .OK else { return }
                destination = panel.url
            }
            guard let destination else { return }
            try project.save(to: destination)
            message = "Saved \(destination.lastPathComponent)"
        } catch { message = error.localizedDescription }
    }
}
