import SwiftUI

struct EditorRootView: View {
    @ObservedObject var document: EditorDocument
    @State private var showPreview = true
    private var model: EditorModel { document.model }

    var body: some View {
        HSplitView {
            EditorTextView(model: model).frame(minWidth: 300)
            if showPreview, let renderer = model.format.makePreviewRenderer() {
                PreviewPane(renderer: renderer, source: model.text).frame(minWidth: 300)
            }
        }
        .toolbar {
            Button { showPreview.toggle() } label: {
                Label("Preview", systemImage: "sidebar.right")
            }
            .disabled(model.format.makePreviewRenderer() == nil)
        }
    }
}
