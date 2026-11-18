import DOTLanguage
import IncrementalParsing
import LanguageTooling
import SwiftUI

@MainActor
final class PadAnalysis: ObservableObject {
    @Published private(set) var sourceText: String?
    @Published private(set) var analysis: LanguageProviderAnalysis?
    @Published private(set) var drawing: DOTPreviewDrawing?
    @Published private(set) var message: String?
    @Published private(set) var drawingText: String?
    private let document = LanguageToolingDocument(provider: DOTProvider())
    private let graphSession = DOTProviderSession()
    private let layout = DOTPreviewLayout()
    private var revision: UInt64 = 0

    func refresh(_ text: String) async {
        do {
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()
            revision += 1
            let snapshot = SourceSnapshot(text: text, revision: .init(revision))
            let result = try await document.update(snapshot)
            try Task.checkCancellation()
            sourceText = text
            analysis = result
            guard text.utf16.count <= 65_536 else {
                message = "Preview is limited to 65,536 UTF-16 units."
                return
            }
            switch try await graphSession.analyzeGraph(snapshot) {
            case .graph(let graph):
                let next = try await layout.draw(graph)
                try Task.checkCancellation()
                drawing = next
                drawingText = text
                message = next.nodes.isEmpty ? "This graph has no nodes." : nil
            case .invalid:
                message = "Check Problems for the current DOT errors."
            case .unsupported(let description):
                message = description
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { message = error.localizedDescription }
        }
    }
}

struct PadEditor: View {
    @Binding var document: DOTDocument
    @StateObject private var services = PadAnalysis()
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var showPreview = true
    @State private var showProblems = true
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            if sizeClass == .regular {
                HStack(spacing: 0) {
                    source
                    if showPreview {
                        Divider()
                        preview.frame(maxWidth: .infinity)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    source
                    if showPreview {
                        Divider()
                        preview.frame(maxHeight: .infinity)
                    }
                }
            }
            if showProblems {
                Divider()
                problems.frame(height: 170)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showProblems.toggle() } label: {
                    Label("Problems", systemImage: "exclamationmark.bubble")
                }
                Button { showPreview.toggle() } label: {
                    Label("Preview", systemImage: "sidebar.right")
                }
            }
        }
        .task(id: document.text) { await services.refresh(document.text) }
    }

    private var source: some View {
        PadTextView(text: $document.text, selection: $selection,
                    tokens: services.sourceText == document.text ? services.analysis?.tokens ?? [] : [])
            .frame(maxWidth: .infinity, maxHeight: .infinity)

    }

    private var preview: some View {
        VStack {
            if let message = services.message {
                Text(services.drawing != nil && services.drawingText != document.text
                     ? "Showing the previous graph. " + message : message)
                    .font(.callout).foregroundStyle(.secondary).padding()
            }
            if let drawing = services.drawing {
                PadGraph(drawing: drawing) { range in
                    guard services.drawingText == document.text else { return }
                    selection = NSRange(location: range.location, length: range.length)
                }
            } else {
                Text("Graph preview").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var problems: some View {
        VStack(alignment: .leading) {
            Text("Problems").font(.headline)
            if services.sourceText == document.text, let analysis = services.analysis {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(analysis.diagnostics) { diagnostic in
                            Button(diagnostic.message) {
                                selection = NSRange(location: diagnostic.range.location, length: diagnostic.range.length)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(Array(analysis.recoveryEdits.enumerated()), id: \.offset) { _, edit in
                            Button(repairTitle(edit)) { apply(edit) }
                        }
                        if analysis.diagnostics.isEmpty { Text("No problems").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Checking…").foregroundStyle(.secondary)
            }
        }.padding()
    }

    private func repairTitle(_ edit: LanguageProviderRecoveryEdit) -> String {
        switch edit.action {
        case .insert(let text, _): "Insert “\(text)”"
        case .replace(let old, _, let text): "Replace “\(old)” with “\(text)”"
        case .delete(let text, _): "Remove “\(text)”"
        case .skip: "Remove unexpected text"
        }
    }

    private func replacement(_ edit: LanguageProviderRecoveryEdit) -> String {
        switch edit.action {
        case .insert(let text, _), .replace(_, _, let text): text
        case .delete, .skip: ""
        }
    }

    private func apply(_ edit: LanguageProviderRecoveryEdit) {
        guard services.sourceText == document.text,
              services.analysis?.recoveryEdits.contains(edit) == true else { return }
        let range = NSRange(location: edit.range.location, length: edit.range.length)
        guard NSMaxRange(range) <= (document.text as NSString).length else { return }
        let value = replacement(edit)
        document.text = (document.text as NSString).replacingCharacters(in: range, with: value)
        selection = NSRange(location: range.location + value.utf16.count, length: 0)
    }
}
