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
                                     publish: model.publishPL0Visualization,
                                     reveal: model.revealSourceRange)
                }
            }
            EditorStatusBar(model: model, formatID: formatID)
        }
    }

    private var formatID: Binding<String> {
        Binding(
            get: { model.format.id },
            set: { id in
                if let format = model.registry.format(withID: id) {
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
                ForEach(model.registry.allFormats, id: \.id) { format in
                    Text(format.displayName).tag(format.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Text("Tab Size: \(model.tabSize)")
                .foregroundStyle(.secondary)

            if let visualization = model.pl0Visualization,
               visualization.version == model.textRevision {
                Text("\(visualization.problemCount) problems")
                    .foregroundStyle(visualization.problemCount == 0
                                     ? Color.secondary : Color.red)
                Text("\(visualization.recoveryCount) repairs")
                    .foregroundStyle(visualization.recoveryCount == 0
                                     ? Color.secondary : Color.orange)
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
