import SwiftUI

/// One editor window: source editor on the left, optional live preview on the right.
@MainActor
struct EditorRootView: View {
    /// `@StateObject` (not `@ObservedObject` on the document): the view must
    /// observe the *model*, whose `text` changes on every keystroke. Observing
    /// only the document, as before, meant the preview never refreshed.
    @StateObject private var model: EditorModel
    @State private var showPreview = true

    init(document: EditorDocument) {
        _model = StateObject(wrappedValue: EditorModel(document: document))
    }

    var body: some View {
        let renderer = model.format.makePreviewRenderer()
        HSplitView {
            EditorTextView(model: model).frame(minWidth: 300)
            if showPreview, let renderer {
                PreviewPane(renderer: renderer, source: model.text).frame(minWidth: 300)
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Format", selection: formatID) {
                    ForEach(FormatRegistry.standard.allFormats, id: \.id) { format in
                        Text(format.displayName).tag(format.id)
                    }
                }
            }
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
