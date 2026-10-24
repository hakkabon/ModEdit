import SwiftUI
import AppKit

struct EditorTextView: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: .zero, usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.attach(to: textView)
        textView.string = model.text
        context.coordinator.highlightEntireDocument()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
    }
}

extension EditorTextView {
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        let model: EditorModel
        weak var textView: NSTextView?
        private var highlightTask: Task<Void, Never>?

        init(model: EditorModel) { self.model = model }

        func attach(to textView: NSTextView) {
            self.textView = textView
            textView.textStorage?.delegate = self
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            model.syncText(textView.string)
        }

        func textStorage(_ textStorage: NSTextStorage,
                         didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            scheduleHighlight(around: editedRange)
        }

        private func scheduleHighlight(around range: NSRange) {
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                self?.highlight(range: range)
            }
        }

        private func highlight(range: NSRange) {
            guard let storage = textView?.textStorage,
                  let highlighter = model.format.makeHighlighter() else { return }
            highlighter.highlight(storage, in: range)
        }

        func highlightEntireDocument() {
            guard let storage = textView?.textStorage,
                  let highlighter = model.format.makeHighlighter() else { return }
            let length = (storage.string as NSString).length
            let chunk = 50_000
            Task { @MainActor in
                for start in stride(from: 0, to: length, by: chunk) {
                    let r = NSRange(location: start, length: min(chunk, length - start))
                    highlighter.highlight(storage, in: r)
                    await Task.yield()
                }
            }
        }
    }
}
