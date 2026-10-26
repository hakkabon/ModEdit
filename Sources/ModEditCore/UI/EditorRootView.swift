import SwiftUI

/// One editor window: source editor on the left, optional live preview on the right.
@MainActor
struct EditorRootView: View {
    /// `@StateObject` (not `@ObservedObject` on the document): the view must
    /// observe the *model*, whose revision changes on every keystroke. Observing
    /// only the document, as before, meant the preview never refreshed.
    @StateObject private var model: EditorModel
    @State private var showPreview = true

    init(document: EditorDocument) {
        _model = StateObject(wrappedValue: EditorModel(document: document))
    }

    var body: some View {
        let renderer = model.format.makePreviewRenderer()
        VStack(spacing: 0) {
            HSplitView {
                EditorTextView(model: model).frame(minWidth: 300)
                if showPreview, let renderer {
                    PreviewPane(renderer: renderer,
                                revision: model.textRevision,
                                source: { model.textSnapshot() })
                        .frame(minWidth: 300)
                }
            }
            EditorStatusBar(model: model, formatID: formatID)
        }
        .toolbar {
            ToolbarItem {
                Button { showPreview.toggle() } label: {
                    Label("Preview", systemImage: "sidebar.right")
                }
                .disabled(renderer == nil)
            }
        }
    }

    private var formatID: Binding<String> {
        Binding(
            get: { model.format.id },
            set: { id in
                if let format = FormatRegistry.standard.format(withID: id) {
                    model.setFormat(format)
                }
            })
    }
}

@MainActor
private struct EditorStatusBar: View {
    @ObservedObject var model: EditorModel
    let formatID: Binding<String>

    var body: some View {
        HStack(spacing: 14) {
            Text("\(model.cursorLine):\(model.cursorColumn)")
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .leading)
                .accessibilityLabel("Cursor line \(model.cursorLine), column \(model.cursorColumn)")

            Picker("Text type", selection: formatID) {
                ForEach(FormatRegistry.standard.allFormats, id: \.id) { format in
                    Text(format.displayName).tag(format.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Text("Tab Size: \(model.tabSize)")
                .foregroundStyle(.secondary)

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
