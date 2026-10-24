import SwiftUI
import AppKit

/// SwiftUI wrapper around a TextKit 2 `NSTextView`.
struct EditorTextView: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: .zero, usingTextLayoutManager: true)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // This is a source editor: never "fix" the user's characters.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView

        // Order matters: load the text *before* attaching the storage delegate.
        // Otherwise the initial load is reported as one giant edit and the
        // whole document is highlighted synchronously, freezing large files.
        // The coordinator instead runs a chunked, cancellable pass.
        textView.string = model.text
        context.coordinator.attach(to: textView)
        context.coordinator.modelDidChange()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // The text view is the live source of truth for the text; only a
        // format change needs action here.
        context.coordinator.modelDidChange()
    }
}

extension EditorTextView {
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        private static let debounce: Duration = .milliseconds(80)
        private static let chunkSize = 50_000

        private let model: EditorModel
        private weak var textView: NSTextView?
        private let theme = EditorTheme()

        /// Highlighter cache: compiling the regular expressions is expensive,
        /// so build once per format instead of once per pass.
        private var highlighter: StorageHighlighter?
        private var highlighterFormatID: String?

        /// Format for which a whole-document pass was last started.
        private var fullPassFormatID: String?

        private var dirty = DirtyRange()
        private var highlightTask: Task<Void, Never>?
        private var fullPassTask: Task<Void, Never>?

        init(model: EditorModel) {
            self.model = model
            super.init()
        }

        deinit {
            highlightTask?.cancel()
            fullPassTask?.cancel()
        }

        func attach(to textView: NSTextView) {
            self.textView = textView
            textView.delegate = self
            textView.textStorage?.delegate = self
        }

        /// Called from `updateNSView`; starts a full pass when the format changed.
        func modelDidChange() {
            guard textView != nil, fullPassFormatID != model.format.id else { return }
            fullPassFormatID = model.format.id
            highlightWholeDocument()
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            model.textDidChange(textView.string)
        }

        // MARK: NSTextStorageDelegate

        func textStorage(_ textStorage: NSTextStorage,
                         didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            // Highlighting only changes attributes; ignoring those edits
            // prevents a feedback loop.
            guard editedMask.contains(.editedCharacters) else { return }
            dirty.record(edited: editedRange, delta: delta)
            scheduleHighlight()
        }

        // MARK: Highlighting

        private func scheduleHighlight() {
            highlightTask?.cancel()
            highlightTask = Task { [weak self] in
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
                self?.flushDirtyRange()
            }
        }

        private func flushDirtyRange() {
            guard let textView, let storage = textView.textStorage else { return }
            // Rewriting attributes while an input method is composing (Japanese,
            // Chinese, Korean...) would wipe the marked-text styling. Wait.
            if textView.hasMarkedText() {
                scheduleHighlight()
                return
            }
            guard let range = dirty.take(clampedTo: storage.length),
                  let highlighter = currentHighlighter() else { return }
            highlighter.apply(to: storage, in: range)
        }

        private func currentHighlighter() -> StorageHighlighter? {
            let format = model.format
            if highlighterFormatID != format.id {
                highlighterFormatID = format.id
                do {
                    highlighter = try StorageHighlighter(rules: format.highlightRules, theme: theme)
                } catch {
                    highlighter = nil
                    assertionFailure("Invalid highlight rule in format \(format.id): \(error)")
                }
            }
            return highlighter
        }

        /// Highlights the document in chunks, yielding between them so the UI
        /// stays responsive. Re-reads the storage length every iteration, so
        /// edits made during the pass cannot produce an out-of-range request.
        private func highlightWholeDocument() {
            fullPassTask?.cancel()
            fullPassTask = Task { [weak self] in
                var start = 0
                while !Task.isCancelled {
                    guard let self,
                          let storage = self.textView?.textStorage,
                          let highlighter = self.currentHighlighter() else { return }
                    let length = storage.length
                    guard start < length else { return }
                    let end = min(start + Self.chunkSize, length)
                    highlighter.apply(to: storage, in: NSRange(location: start, length: end - start))
                    start = end
                    await Task.yield()
                }
            }
        }
    }
}
