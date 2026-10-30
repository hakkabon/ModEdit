import SwiftUI
import AppKit
import PL0Language

/// SwiftUI wrapper around an AppKit `NSTextView`.
struct EditorTextView: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = EditorNSTextView(frame: .zero)
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

        let theme = context.coordinator.theme
        textView.drawsBackground = true
        textView.backgroundColor = theme.backgroundColor
        textView.currentLineColor = theme.currentLineColor
        textView.insertionPointColor = theme.insertionPointColor
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        let spaceWidth = textView.font?.maximumAdvancement.width ?? 8
        paragraphStyle.defaultTabInterval = spaceWidth * CGFloat(model.tabSize)
        paragraphStyle.tabStops = []
        textView.defaultParagraphStyle = paragraphStyle
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        // Load before constructing the gutter so it starts from the opened
        // document's text and line count rather than an empty text view.
        textView.string = model.textSnapshot()
        scrollView.documentView = textView
        let ruler = LineNumberRulerView(textView: textView,
                                        scrollView: scrollView,
                                        lineSource: model,
                                        theme: theme)
        scrollView.verticalRulerView = ruler
        ruler.refreshLineCount()
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        // Order matters: load the text *before* attaching the storage delegate.
        // Otherwise the initial load is reported as one giant edit and the
        // whole document is highlighted synchronously, freezing large files.
        // The coordinator instead runs a chunked, cancellable pass.
        context.coordinator.attach(to: textView)
        context.coordinator.modelDidChange()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Synchronize first: the ruler must read the new text, not the old one.
        context.coordinator.synchronizeFromDocumentIfNeeded()
        (scrollView.verticalRulerView as? LineNumberRulerView)?.refreshLineCount()
        context.coordinator.modelDidChange()
    }
}

extension EditorTextView {
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        private static let debounce: Duration = .milliseconds(80)
        private static let chunkSize = 50_000

        private let model: EditorModel
        private weak var textView: NSTextView?
        let theme = EditorTheme()

        /// Highlighter cache: compiling the regular expressions is expensive,
        /// so build once per format instead of once per pass.
        private var highlighter: StorageHighlighter?
        private var highlighterFormatID: String?

        /// Format for which a whole-document pass was last started.
        private var fullPassFormatID: String?

        private var dirty = DirtyRange()
        private var highlightTask: Task<Void, Never>?
        private var fullPassTask: Task<Void, Never>?
        private var synchronizedGeneration: UInt64 = 0
        private var isSynchronizing = false
        private var displayedVisualization: PL0EditorVisualization?
        private var handledRevealID: UInt64 = 0

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
            synchronizedGeneration = model.documentTextGeneration
            textView.delegate = self
            textView.textStorage?.delegate = self
            updateCursorLocation()
        }

        /// Pulls replacements such as Revert to Saved into the AppKit view.
        /// Edits originating in this view update `synchronizedGeneration`
        /// immediately and therefore do not cause a full-string comparison.
        func synchronizeFromDocumentIfNeeded() {
            guard let textView else { return }
            let generation = model.documentTextGeneration
            guard generation != synchronizedGeneration else { return }
            isSynchronizing = true
            textView.string = model.textSnapshot()
            synchronizedGeneration = generation
            isSynchronizing = false
            clearParserVisualization()
            dirty = DirtyRange()
            // The whole text was replaced; every cached scanner state refers to
            // text that no longer exists.
            highlighter?.invalidateCheckpoints()
            // Do not publish model state from inside `updateNSView`; refresh
            // after the current view update has finished.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.model.refreshAfterExternalChange()
                self.updateCursorLocation()
            }
            highlightWholeDocument()
        }

        /// Called from `updateNSView`; starts a full pass when the format changed.
        func modelDidChange() {
            refreshParserVisualization()
            fulfillRevealRequest()
            guard textView != nil, fullPassFormatID != model.format.id else { return }
            fullPassFormatID = model.format.id
            highlightWholeDocument()
        }

        // MARK: NSTextViewDelegate

        func textViewDidChangeSelection(_ notification: Notification) {
            // The external-sync path refreshes the cursor after its view update.
            guard !isSynchronizing else { return }
            updateCursorLocation()
            textView?.needsDisplay = true
        }

        private func updateCursorLocation() {
            guard let textView else { return }
            let length = textView.textStorage?.length ?? 0
            let location = min(textView.selectedRange().location, length)
            let position = model.lineAndColumn(at: location)
            model.updateCursor(line: position.line, column: position.column)
            (textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?
                .updateCurrentLine(position.line)
        }

        // MARK: NSTextStorageDelegate

        func textStorage(_ textStorage: NSTextStorage,
                         didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            // Highlighting only changes attributes; ignoring those edits
            // prevents a feedback loop.
            guard editedMask.contains(.editedCharacters) else { return }
            if !isSynchronizing {
                // Read only the replacement; do not materialize the whole file.
                let replacement = (textStorage.mutableString as NSString)
                    .substring(with: editedRange)
                synchronizedGeneration = model.applyTextEdit(
                    editedRange: editedRange, delta: delta, replacement: replacement)
            }
            clearParserVisualization()
            dirty.record(edited: editedRange, delta: delta)
            // A character change can invalidate the Markdown/HTML scanner state
            // for the edit point and everything after it.
            highlighter?.invalidateCheckpoints(from: editedRange.location)
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
                    highlighter = try StorageHighlighter(rules: format.highlightRules,
                                                         scanner: format.scanner,
                                                         theme: theme)
                } catch {
                    highlighter = nil
                    assertionFailure("Invalid highlight rule in format \(format.id): \(error)")
                }
            }
            return highlighter
        }

        // MARK: Parser visualization

        /// Parser annotations are temporary layout attributes. They never enter
        /// text storage, so syntax highlighting, undo and file output remain
        /// unchanged.
        func refreshParserVisualization() {
            let visualization = model.pl0Visualization
            guard visualization != displayedVisualization else { return }
            clearParserVisualization()
            guard let visualization,
                  visualization.version == model.textRevision,
                  let textView,
                  let layoutManager = textView.layoutManager else { return }
            let length = textView.textStorage?.length ?? 0
            for annotation in visualization.annotations {
                guard let range = displayRange(for: annotation.range, length: length) else {
                    continue
                }
                var attributes = attributes(for: annotation)
                attributes[Self.parserMarker] = true
                layoutManager.addTemporaryAttributes(attributes, forCharacterRange: range)
            }
            displayedVisualization = visualization
            textView.needsDisplay = true
        }

        func fulfillRevealRequest() {
            guard let request = model.revealRequest,
                  request.id != handledRevealID,
                  let textView else { return }
            handledRevealID = request.id
            let length = textView.textStorage?.length ?? 0
            let location = min(max(request.range.location, 0), length)
            let end = min(max(request.range.end, location), length)
            let selection = NSRange(location: location, length: end - location)
            textView.setSelectedRange(selection)
            textView.scrollRangeToVisible(selection)
            textView.window?.makeFirstResponder(textView)
        }

        private func clearParserVisualization() {
            guard let textView, let layoutManager = textView.layoutManager else {
                displayedVisualization = nil
                return
            }
            let length = textView.textStorage?.length ?? 0
            var cursor = 0
            while cursor < length {
                var effectiveRange = NSRange(location: cursor, length: 1)
                let marker = layoutManager.temporaryAttribute(
                    Self.parserMarker, atCharacterIndex: cursor,
                    effectiveRange: &effectiveRange)
                let next = max(cursor + 1, NSMaxRange(effectiveRange))
                if marker != nil {
                    for key in Self.parserAttributeKeys {
                        layoutManager.removeTemporaryAttribute(
                            key, forCharacterRange: effectiveRange)
                    }
                }
                cursor = next
            }
            displayedVisualization = nil
            textView.needsDisplay = true
        }

        private func displayRange(for range: SourceRange, length: Int) -> NSRange? {
            guard length > 0 else { return nil }
            let location = min(max(range.location, 0), length)
            let end = min(max(range.end, location), length)
            if end > location {
                return NSRange(location: location, length: end - location)
            }
            // Missing tokens have zero-width source ranges. Anchor their visual
            // marker to the following character, or the preceding one at EOF.
            let anchor = location < length ? location : length - 1
            return NSRange(location: anchor, length: 1)
        }

        private func attributes(for annotation: PL0EditorVisualization.Annotation)
            -> [NSAttributedString.Key: Any] {
            let tooltip = annotation.message
            switch annotation.kind {
            case .error:
                return [.underlineStyle: Self.problemUnderline,
                        .underlineColor: NSColor.systemRed,
                        .toolTip: tooltip]
            case .warning:
                return [.underlineStyle: Self.problemUnderline,
                        .underlineColor: NSColor.systemOrange,
                        .toolTip: tooltip]
            case .information:
                return [.underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: NSColor.systemBlue,
                        .toolTip: tooltip]
            case .missingToken:
                return [.underlineStyle: NSUnderlineStyle.thick.rawValue,
                        .underlineColor: NSColor.systemOrange,
                        .backgroundColor: NSColor.systemOrange.withAlphaComponent(0.18),
                        .toolTip: tooltip]
            case .skippedToken:
                return [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: NSColor.systemRed,
                        .backgroundColor: NSColor.systemRed.withAlphaComponent(0.14),
                        .toolTip: tooltip]
            }
        }

        private static let problemUnderline = NSUnderlineStyle.thick
            .union(.patternDot).rawValue
        private static let parserMarker = NSAttributedString.Key(
            "io.github.hakkabon.ModEdit.parser-annotation")
        private static let parserAttributeKeys: [NSAttributedString.Key] = [
            .underlineStyle, .underlineColor, .strikethroughStyle,
            .strikethroughColor, .backgroundColor, .toolTip, parserMarker,
        ]

        /// Highlights the document in line-aligned chunks, yielding between
        /// them so the UI stays responsive.
        ///
        /// Chunks share one `Tokenizer.State`, so a full pass visits every
        /// character once instead of re-scanning the document prefix per chunk.
        /// Re-reading the storage length every iteration prevents an edit made
        /// during the pass from producing an out-of-range request; if an edit
        /// did change the text, the carried state is stale, so the pass
        /// restarts from the beginning.
        private func highlightWholeDocument() {
            fullPassTask?.cancel()
            fullPassTask = Task { [weak self] in
                var start = 0
                var state = Tokenizer.State()
                var generation = self?.synchronizedGeneration

                while !Task.isCancelled {
                    guard let self,
                          let storage = self.textView?.textStorage,
                          let highlighter = self.currentHighlighter() else { return }

                    if generation != self.synchronizedGeneration {
                        start = 0
                        state = Tokenizer.State()
                        generation = self.synchronizedGeneration
                    }

                    let length = storage.length
                    guard start < length else { return }

                    let text = storage.mutableString
                    let tentativeEnd = min(start + Self.chunkSize, length)
                    let lineRange = text.lineRange(
                        for: NSRange(location: start, length: tentativeEnd - start))
                    let end = min(NSMaxRange(lineRange), length)
                    guard end > start else { return }

                    highlighter.apply(to: storage,
                                      in: NSRange(location: start, length: end - start),
                                      state: &state)
                    start = end
                    await Task.yield()
                }
            }
        }
    }
}
