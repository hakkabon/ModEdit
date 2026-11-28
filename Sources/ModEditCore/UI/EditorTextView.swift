import SwiftUI
import AppKit
import CoreText
import PL0Language
import RenderedText

/// SwiftUI wrapper around an AppKit `NSTextView`.
struct EditorTextView: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    @ObservedObject private var preferences: EditorPreferences

    init(model: EditorModel) {
        _model = ObservedObject(wrappedValue: model)
        _preferences = ObservedObject(wrappedValue: model.preferences)
    }

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
        textView.font = theme.baseFont
        let paragraphStyle = NSMutableParagraphStyle()
        let spaceWidth = theme.baseFont.maximumAdvancement.width
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
        context.coordinator.applyPreferences(in: scrollView)
        context.coordinator.modelDidChange()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.applyPreferences(in: scrollView)
        // Synchronize first: the ruler must read the new text, not the old one.
        context.coordinator.synchronizeFromDocumentIfNeeded()
        (scrollView.verticalRulerView as? LineNumberRulerView)?.refreshLineCount()
        context.coordinator.modelDidChange()
    }
}

extension EditorTextView {
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate,
                             @preconcurrency NSLayoutManagerDelegate,
                             @preconcurrency NSTextStorageDelegate {
        private static let debounce: Duration = .milliseconds(80)
        private static let chunkSize = 50_000

        private let model: EditorModel
        private weak var textView: NSTextView?
        private(set) var theme: EditorTheme
        private var renderedStyler: RenderedEditorStyler
        private let renderedImageCache = RenderedEditorImageCache()
        /// Settings last copied into AppKit. `nil` until the first view update.
        private var appliedSettings: EditorSettings?

        /// Highlighter cache: compiling the regular expressions is expensive,
        /// so build once per format instead of once per pass.
        private var highlighter: StorageHighlighter?
        private var highlighterFormatID: String?

        /// Format for which a whole-document pass was last started.
        private var fullPassFormatID: String?

        private var dirty = DirtyRange()
        private var highlightTask: Task<Void, Never>?
        private var fullPassTask: Task<Void, Never>?
        private var renderedTask: Task<Void, Never>?
        private var synchronizedGeneration: UInt64 = 0
        private var isSynchronizing = false
        private var isProcessingCharacterEdit = false
        private var displayedVisualization: PL0EditorVisualization?
        private var handledRevealID: UInt64 = 0
        private var handledScrollID: UInt64 = 0
        private var handledReplacementID: UInt64 = 0

        /// Rendered-editing state. The presentation is rebuilt only when the
        /// mode changes or the text changes outside this coordinator; ordinary
        /// edits apply incrementally.
        private var renderedModeActive = false
        private var renderedPresentation: RenderedEditorPresentation?
        private var renderedGeneration: UInt64?
        private var lastRenderedActiveLine: Range<Int>?
        private var lastRenderedImageLines: [Range<Int>] = []
        private var substitutionGlyphCache: [SubstitutionGlyphKey: [CGGlyph]] = [:]

        private struct SubstitutionGlyphKey: Hashable {
            let text: String
            let fontName: String
            let pointSize: CGFloat
        }

        init(model: EditorModel) {
            self.model = model
            let theme = model.preferences.theme
            self.theme = theme
            self.renderedStyler = RenderedEditorStyler(theme: theme, tabSize: model.tabSize)
            super.init()
        }

        deinit {
            highlightTask?.cancel()
            fullPassTask?.cancel()
            renderedTask?.cancel()
        }

        /// Copies appearance, font and wrapping changes into the live view.
        ///
        /// Font and size changes invalidate cached scanner/styler state and
        /// re-highlight through the normal chunked or rendered path. Wrapping
        /// changes only adjust the text container, so they leave attributes
        /// alone.
        func applyPreferences(in scrollView: NSScrollView) {
            let settings = model.preferences.settings
            let previous = appliedSettings
            guard settings != previous else { return }
            appliedSettings = settings

            let newTheme = model.preferences.theme
            let fontsChanged = previous.map {
                $0.fontFamily != settings.fontFamily
                    || $0.fontSize != settings.fontSize
            } ?? false
            theme = newTheme
            if fontsChanged {
                renderedStyler = RenderedEditorStyler(theme: newTheme,
                                                      tabSize: model.tabSize)
                highlighter = nil
                highlighterFormatID = nil
            }

            if let textView {
                textView.font = newTheme.baseFont
                textView.backgroundColor = newTheme.backgroundColor
                (textView as? EditorNSTextView)?.currentLineColor =
                    newTheme.currentLineColor
                textView.insertionPointColor = newTheme.insertionPointColor
                textView.typingAttributes = newTheme.baseAttributes
                let paragraph = NSMutableParagraphStyle()
                paragraph.defaultTabInterval =
                    newTheme.baseFont.maximumAdvancement.width
                        * CGFloat(model.tabSize)
                paragraph.tabStops = []
                textView.defaultParagraphStyle = paragraph
                (textView as? EditorNSTextView)?.renderedImageBackgroundColor =
                    newTheme.backgroundColor
                EditorSoftWrap.apply(settings.softWrap, to: textView,
                                     in: scrollView)
                textView.needsDisplay = true
            }
            scrollView.backgroundColor = newTheme.backgroundColor
            (scrollView.verticalRulerView as? LineNumberRulerView)?
                .setTheme(newTheme)

            guard fontsChanged else { return }
            fullPassFormatID = nil
            if model.isRenderedEditingActive {
                scheduleRenderedProjection(full: true, delay: .zero)
            } else {
                fullPassFormatID = model.format.id
                highlightWholeDocument()
            }
        }

        func attach(to textView: NSTextView) {
            self.textView = textView
            synchronizedGeneration = model.documentTextGeneration
            textView.delegate = self
            textView.textStorage?.delegate = self
            textView.layoutManager?.delegate = self
            if let editor = textView as? EditorNSTextView {
                editor.renderedImageBackgroundColor = theme.backgroundColor
                editor.renderedNavigation = { [weak self, weak textView] direction, extending in
                    guard let self, let textView else { return false }
                    return self.moveRenderedCaret(
                        in: textView, direction: direction, extending: extending)
                }
            }
            updateCursorLocation()
        }

        /// Pulls replacements such as Revert to Saved into the AppKit view.
        /// Edits originating in this view update `synchronizedGeneration`
        /// immediately and therefore do not cause a full-string comparison.
        func synchronizeFromDocumentIfNeeded() {
            guard let textView else { return }
            let generation = model.documentTextGeneration
            guard generation != synchronizedGeneration else { return }
            clearParserVisualization()
            isSynchronizing = true
            textView.string = model.textSnapshot()
            synchronizedGeneration = generation
            isSynchronizing = false
            dirty = DirtyRange()
            // The whole text was replaced; every cached scanner state refers to
            // text that no longer exists.
            highlighter?.invalidateCheckpoints()
            lastRenderedImageLines = []
            (textView as? EditorNSTextView)?.renderedImages = []
            // Do not publish model state from inside `updateNSView`; refresh
            // after the current view update has finished.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.model.refreshAfterExternalChange()
                self.updateCursorLocation()
            }
            if model.isRenderedEditingActive {
                rebuildRenderedPresentation()
                scheduleRenderedProjection(full: true, delay: .zero)
            } else {
                highlightWholeDocument()
            }
        }

        /// Called from `updateNSView`; starts a full pass when the format changed.
        func modelDidChange() {
            fulfillSourceReplacementRequest()
            refreshParserVisualization()
            if let request = model.revealRequest, request.id != handledRevealID {
                // Selecting text fires the AppKit delegate. Publish the new
                // selection after SwiftUI finishes updating the representable.
                Task { @MainActor [weak self] in self?.fulfillRevealRequest() }
            }
            if let request = model.editorScrollRequest, request.id != handledScrollID {
                Task { @MainActor [weak self] in self?.fulfillEditorScrollRequest() }
            }
            updateRenderedEditingMode()
            guard !model.isRenderedEditingActive else { return }
            guard textView != nil, fullPassFormatID != model.format.id else { return }
            fullPassFormatID = model.format.id
            highlightWholeDocument()
        }

        // MARK: NSTextViewDelegate

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            if replacementString != nil {
                clearParserVisualization()
            }
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // The external-sync path refreshes the cursor after its view update.
            guard !isSynchronizing else { return }
            updateCursorLocation()
            textView?.needsDisplay = true
            renderedSelectionDidChange()
        }

        private func updateCursorLocation() {
            guard let textView else { return }
            let length = textView.textStorage?.length ?? 0
            let location = min(textView.selectedRange().location, length)
            let position = model.lineAndColumn(at: location)
            model.updateCursor(line: position.line, column: position.column,
                               selection: textView.selectedRange())
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
            isProcessingCharacterEdit = true
            defer { isProcessingCharacterEdit = false }

            let oldRange = NSRange(location: editedRange.location,
                                   length: editedRange.length - delta)
            var replacement = ""
            if !isSynchronizing {
                // Read only the replacement; do not materialize the whole file.
                replacement = (textStorage.mutableString as NSString)
                    .substring(with: editedRange)
                synchronizedGeneration = model.applyTextEdit(
                    editedRange: editedRange, delta: delta, replacement: replacement)
            }
            // Direct storage edits bypass shouldChangeTextIn. Wait until
            // TextKit has processed the edit before touching layout attributes.
            if displayedVisualization != nil {
                Task { @MainActor [weak self] in self?.refreshParserVisualization() }
            }
            // A character change can invalidate the Markdown/HTML scanner state
            // for the edit point and everything after it.
            highlighter?.invalidateCheckpoints(from: editedRange.location)

            if model.isRenderedEditingActive {
                if !isSynchronizing {
                    observeRenderedEdit(oldRange: oldRange, replacement: replacement,
                                        textStorage: textStorage)
                }
                scheduleRenderedProjection(full: true,
                                           delay: .milliseconds(25))
            } else {
                dirty.record(edited: editedRange, delta: delta)
                scheduleHighlight()
            }
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

        // MARK: Rendered editing

        /// Starts, stops or refreshes live rendered editing after a model
        /// change. The expensive full-document pass is always deferred; mode
        /// changes happen while SwiftUI is updating the view.
        private func updateRenderedEditingMode() {
            let active = model.isRenderedEditingActive
            if active {
                let length = textView?.textStorage?.length ?? 0
                if !renderedModeActive {
                    renderedModeActive = true
                    fullPassFormatID = nil
                    rebuildRenderedPresentation()
                    scheduleRenderedProjection(full: true, delay: .zero)
                } else if renderedPresentation == nil
                            || renderedGeneration != synchronizedGeneration
                            || renderedPresentation?.sourceLength != length {
                    rebuildRenderedPresentation()
                    scheduleRenderedProjection(full: true, delay: .zero)
                }
            } else if renderedModeActive {
                renderedModeActive = false
                renderedPresentation = nil
                renderedGeneration = nil
                lastRenderedActiveLine = nil
                renderedTask?.cancel()
                highlighter?.invalidateCheckpoints()
                // Image line heights and cleared text colour must not leak into
                // source mode.
                if let storage = textView?.textStorage {
                    resetRenderedImageLines(in: storage)
                }
                if let editor = textView as? EditorNSTextView {
                    editor.renderedImages = []
                }
                // Substituted glyphs must return to their source spelling.
                let length = textView?.textStorage?.length ?? 0
                invalidateRenderedGlyphs(in: 0..<length)
                // Let `modelDidChange` start a source-highlighting pass for the
                // plain presentation.
                fullPassFormatID = nil
            }
        }

        private func rebuildRenderedPresentation() {
            guard let storage = textView?.textStorage else {
                renderedPresentation = nil
                renderedGeneration = nil
                return
            }
            do {
                renderedPresentation = try RenderedEditorPresentation(source: storage.string)
                renderedGeneration = synchronizedGeneration
                lastRenderedActiveLine = nil
            } catch {
                renderedPresentation = nil
                renderedGeneration = nil
                assertionFailure("Rendered Markdown projection failed: \(error)")
            }
        }

        /// Keeps the projection in sync with one character edit. Applying the
        /// edit incrementally reuses unchanged blocks and avoids reparsing the
        /// whole document into fresh block identities.
        private func observeRenderedEdit(oldRange: NSRange,
                                         replacement: String,
                                         textStorage: NSTextStorage) {
            guard let presentation = renderedPresentation,
                  presentation.sourceLength == oldRange.location + oldRange.length else {
                rebuildRenderedPresentation()
                return
            }
            do {
                var updated = presentation
                try updated.apply(SourceEdit(
                    range: oldRange.location..<(oldRange.location + oldRange.length),
                    replacement: replacement))
                renderedPresentation = updated
                renderedGeneration = synchronizedGeneration
            } catch {
                rebuildRenderedPresentation()
            }
        }

        private func scheduleRenderedProjection(full: Bool, delay: Duration) {
            renderedTask?.cancel()
            renderedTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.applyRenderedProjection(full: full)
            }
        }

        /// Applies the current presentation to text-storage attributes.
        ///
        /// `full` restyles the whole document. Otherwise only the previous and
        /// current caret lines are reset, which is what makes moving the caret
        /// through rendered text cheap.
        func applyRenderedProjection(full: Bool) {
            guard model.isRenderedEditingActive,
                  let textView,
                  let storage = textView.textStorage else { return }

            if renderedPresentation == nil || renderedGeneration != synchronizedGeneration {
                rebuildRenderedPresentation()
            }
            guard let presentation = renderedPresentation,
                  presentation.sourceLength == storage.length else {
                resetRenderedImageLines(in: storage)
                if let editor = textView as? EditorNSTextView {
                    editor.renderedImages = []
                }
                return
            }
            if textView.hasMarkedText() {
                scheduleRenderedProjection(full: full, delay: .milliseconds(80))
                return
            }
            guard storage.length > 0 else {
                lastRenderedActiveLine = nil
                resetRenderedImageLines(in: storage)
                (textView as? EditorNSTextView)?.renderedImages = []
                return
            }

            let activeLine = activeLineRange(in: textView)
            let ranges: [Range<Int>]
            if full || lastRenderedActiveLine == nil {
                ranges = [0..<storage.length]
            } else if let old = lastRenderedActiveLine, old != activeLine {
                if old.overlaps(activeLine) {
                    let lower = min(old.lowerBound, activeLine.lowerBound)
                    let upper = max(old.upperBound, activeLine.upperBound)
                    ranges = [lower..<upper]
                } else {
                    ranges = [old, activeLine]
                }
            } else {
                ranges = []
            }

            let source = storage.mutableString
            for range in ranges where !range.isEmpty {
                applyRenderedStyles(presentation: presentation,
                                    to: storage,
                                    in: range,
                                    activeLine: activeLine,
                                    source: source)
            }

            // Image attachments change line height and clear the source
            // colour. Do this before the caret-line highlighting, so an image
            // line that just became active does not lose its syntax colours.
            let imageLines = updateRenderedImages(
                presentation: presentation, activeLine: activeLine, in: textView)

            if activeLine.lowerBound < activeLine.upperBound {
                currentHighlighter()?.apply(
                    to: storage,
                    in: NSRange(location: activeLine.lowerBound,
                                length: activeLine.count))
            }
            textView.typingAttributes = theme.baseAttributes
            lastRenderedActiveLine = activeLine

            for range in ranges {
                invalidateRenderedGlyphs(in: range)
            }
            for range in imageLines {
                invalidateRenderedGlyphs(in: range)
            }
        }

        /// Loads standalone images and reserves their line height. Returns the
        /// line ranges whose layout attributes changed.
        @discardableResult
        private func updateRenderedImages(presentation: RenderedEditorPresentation,
                                          activeLine: Range<Int>,
                                          in textView: NSTextView) -> [Range<Int>] {
            guard let storage = textView.textStorage,
                  let editor = textView as? EditorNSTextView else { return [] }
            let oldLines = lastRenderedImageLines
            resetRenderedImageLines(in: storage)

            guard model.isRenderedEditingActive else {
                editor.renderedImages = []
                return oldLines
            }
            renderedImageCache.setBaseURL(model.resourceBaseURL)
            let loaded = renderedImageCache.loadImages(for: presentation.images)
            guard !loaded.isEmpty else {
                editor.renderedImages = []
                return oldLines
            }

            let availableWidth = max(0, (textView.textContainer?.containerSize.width
                ?? textView.bounds.width) - textView.textContainerInset.width * 2)
            var attachments: [EditorNSTextView.RenderedImageAttachment] = []
            var newLines: [Range<Int>] = []

            for item in loaded {
                let line = presentation.lineRange(containing: item.sourceRange.lowerBound)
                guard !activeLine.overlaps(line) else { continue }
                let clipped = clippedRange(line, to: storage.length)
                guard !clipped.isEmpty else { continue }
                let imageSize = item.image.size
                let displaySize = EditorNSTextView.displaySize(
                    for: imageSize, availableWidth: availableWidth)
                guard displaySize.width > 0, displaySize.height > 0 else { continue }

                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight =
                    EditorNSTextView.reservedImageHeight(for: displaySize)
                storage.addAttributes([
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: paragraph,
                ], range: NSRange(location: clipped.lowerBound,
                                  length: clipped.count))
                attachments.append(.init(
                    sourceRange: item.sourceRange,
                    lineRange: clipped,
                    image: item.image,
                    displaySize: displaySize))
                newLines.append(clipped)
            }

            lastRenderedImageLines = newLines
            editor.renderedImages = attachments
            return oldLines + newLines
        }

        /// Restores the base attributes on lines whose height or colour was
        /// changed for an image attachment.
        private func resetRenderedImageLines(in storage: NSTextStorage) {
            guard !lastRenderedImageLines.isEmpty else { return }
            for line in lastRenderedImageLines {
                let clipped = clippedRange(line, to: storage.length)
                guard !clipped.isEmpty else { continue }
                storage.setAttributes(
                    theme.baseAttributes,
                    range: NSRange(location: clipped.lowerBound, length: clipped.count))
            }
            lastRenderedImageLines = []
        }

        private func clippedRange(_ range: Range<Int>, to length: Int) -> Range<Int> {
            let lower = max(0, min(range.lowerBound, length))
            let upper = max(lower, min(range.upperBound, length))
            return lower..<upper
        }

        private func invalidateRenderedGlyphs(in range: Range<Int>) {
            guard !range.isEmpty,
                  let layoutManager = textView?.layoutManager else { return }
            let characterRange = NSRange(location: range.lowerBound,
                                         length: range.count)
            layoutManager.invalidateGlyphs(
                forCharacterRange: characterRange,
                changeInLength: 0,
                actualCharacterRange: nil)
            layoutManager.invalidateLayout(
                forCharacterRange: characterRange,
                actualCharacterRange: nil)
        }

        // MARK: Rendered glyph substitution

        /// Replaces source glyphs with their rendered spelling without touching
        /// text storage. Each display unit occupies the source slot it replaces;
        /// extra source slots become null glyphs, so layout width equals the
        /// projection's display width while offsets, undo and saving stay tied
        /// to the source.
        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes charIndexes: UnsafePointer<Int>,
            font aFont: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard model.isRenderedEditingActive,
                  let presentation = renderedPresentation,
                  !presentation.substitutions.isEmpty,
                  let storage = layoutManager.textStorage,
                  presentation.sourceLength == storage.length,
                  glyphRange.length > 0 else { return 0 }

            var modifiedGlyphs = Array(UnsafeBufferPointer(
                start: glyphs, count: glyphRange.length))
            var modifiedProperties = Array(UnsafeBufferPointer(
                start: props, count: glyphRange.length))
            var changed = false

            for index in 0..<glyphRange.length {
                let characterIndex = charIndexes[index]
                guard let substitution = presentation.substitution(at: characterIndex),
                      !(lastRenderedActiveLine?.overlaps(substitution.sourceRange) ?? false),
                      let displayGlyphs = displayGlyphs(
                        for: substitution.displayText, font: aFont) else { continue }

                let offset = characterIndex - substitution.sourceRange.lowerBound
                if offset < displayGlyphs.count {
                    modifiedGlyphs[index] = displayGlyphs[offset]
                    modifiedProperties[index].remove(.null)
                } else {
                    modifiedGlyphs[index] = 0
                    modifiedProperties[index] = .null
                }
                changed = true
            }

            guard changed else { return 0 }
            modifiedGlyphs.withUnsafeBufferPointer { glyphBuffer in
                modifiedProperties.withUnsafeBufferPointer { propertyBuffer in
                    layoutManager.setGlyphs(
                        glyphBuffer.baseAddress!,
                        properties: propertyBuffer.baseAddress!,
                        characterIndexes: charIndexes,
                        font: aFont,
                        forGlyphRange: glyphRange)
                }
            }
            return glyphRange.length
        }

        /// Glyphs for a display string in the font the layout manager is using.
        ///
        /// Fonts without every glyph keep the source spelling instead of
        /// drawing a missing-glyph box. Surrogate pairs and combining sequences
        /// are left alone because one source slot cannot represent them
        /// reliably.
        private func displayGlyphs(for text: String, font: NSFont) -> [CGGlyph]? {
            let key = SubstitutionGlyphKey(
                text: text, fontName: font.fontName, pointSize: font.pointSize)
            if let cached = substitutionGlyphCache[key] {
                return cached.isEmpty ? nil : cached
            }

            let units = Array(text.utf16)
            guard !units.isEmpty,
                  units.count == text.unicodeScalars.count else {
                substitutionGlyphCache[key] = []
                return nil
            }
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            let ctFont = font as CTFont
            let found = units.withUnsafeBufferPointer { characters in
                glyphs.withUnsafeMutableBufferPointer { buffer in
                    CTFontGetGlyphsForCharacters(
                        ctFont, characters.baseAddress!, buffer.baseAddress!,
                        units.count)
                }
            }
            guard found, !glyphs.contains(0) else {
                substitutionGlyphCache[key] = []
                return nil
            }
            substitutionGlyphCache[key] = glyphs
            return glyphs
        }

        private func applyRenderedStyles(presentation: RenderedEditorPresentation,
                                         to storage: NSTextStorage,
                                         in range: Range<Int>,
                                         activeLine: Range<Int>,
                                         source: NSString) {
            let spans = presentation.spans(intersecting: range, activeLine: activeLine)
            storage.beginEditing()
            storage.setAttributes(
                theme.baseAttributes,
                range: NSRange(location: range.lowerBound, length: range.count))
            renderedStyler.apply(spans: spans,
                                 to: storage,
                                 clippedTo: range,
                                 source: source)
            storage.endEditing()
        }

        /// Re-renders when the caret (or a selection endpoint) moves to another
        /// line, revealing that line's markup and collapsing the previous one.
        private func renderedSelectionDidChange() {
            guard model.isRenderedEditingActive,
                  renderedPresentation != nil,
                  !isSynchronizing,
                  let textView,
                  !textView.hasMarkedText() else { return }
            let active = activeLineRange(in: textView)
            guard active != lastRenderedActiveLine else { return }
            applyRenderedProjection(full: false)
        }

        /// Synchronous source-highlighting pass used when rendered editing is
        /// turned off and by tests. Production normally uses the chunked pass.
        func applySourceHighlightingNow() {
            guard let storage = textView?.textStorage,
                  let highlighter = currentHighlighter() else { return }
            highlighter.invalidateCheckpoints()
            highlighter.apply(to: storage,
                              in: NSRange(location: 0, length: storage.length))
            textView?.typingAttributes = theme.baseAttributes
        }

        /// The current projection, exposed for tests that need to assert the
        /// host and the presentation agree.
        var presentationForTesting: RenderedEditorPresentation? {
            renderedPresentation
        }

        /// Image attachments currently installed in the text view, for tests.
        var renderedImageAttachmentsForTesting: [EditorNSTextView.RenderedImageAttachment] {
            (textView as? EditorNSTextView)?.renderedImages ?? []
        }

        /// Source lines whose height was reserved for an image, for tests.
        var renderedImageLinesForTesting: [Range<Int>] {
            lastRenderedImageLines
        }

        private func activeLineRange(in textView: NSTextView) -> Range<Int> {
            guard let storage = textView.textStorage else { return 0..<0 }
            let length = storage.length
            let location = min(max(textView.selectedRange().location, 0), length)
            let line = storage.mutableString.lineRange(
                for: NSRange(location: location, length: 0))
            return line.location..<NSMaxRange(line)
        }

        /// Moves the caret through display positions outside the active line.
        /// Returns `false` when the caller should fall back to AppKit.
        private func moveRenderedCaret(in textView: NSTextView,
                                       direction: Int,
                                       extending: Bool) -> Bool {
            guard model.isRenderedEditingActive,
                  let storage = textView.textStorage,
                  let presentation = renderedPresentation,
                  presentation.sourceLength == storage.length,
                  presentation.sourceLength > 0 else { return false }

            let length = storage.length
            let location = min(max(textView.selectedRange().location, 0), length)
            let selectionLength = min(max(textView.selectedRange().length, 0),
                                      length - location)
            let current = NSRange(location: location, length: selectionLength)
            let activeLine = activeLineRange(in: textView)

            let next: NSRange
            if extending {
                if current.length == 0 {
                    let target = presentation.nextSourceOffset(
                        from: current.location, direction: direction,
                        activeLine: activeLine)
                    if direction < 0 {
                        next = NSRange(location: target,
                                       length: max(0, current.location - target))
                    } else {
                        next = NSRange(location: current.location,
                                       length: max(0, target - current.location))
                    }
                } else if direction < 0 {
                    let target = presentation.nextSourceOffset(
                        from: current.location, direction: -1,
                        activeLine: activeLine)
                    next = NSRange(location: target,
                                   length: max(0, NSMaxRange(current) - target))
                } else {
                    let upper = NSMaxRange(current)
                    let target = presentation.nextSourceOffset(
                        from: upper, direction: 1, activeLine: activeLine)
                    next = NSRange(location: current.location,
                                   length: max(0, target - current.location))
                }
            } else if current.length > 0 {
                next = direction < 0
                    ? NSRange(location: current.location, length: 0)
                    : NSRange(location: NSMaxRange(current), length: 0)
            } else {
                let target = presentation.nextSourceOffset(
                    from: current.location, direction: direction,
                    activeLine: activeLine)
                next = NSRange(location: target, length: 0)
            }

            guard next != current else { return true }
            textView.setSelectedRange(next)
            textView.scrollRangeToVisible(next)
            return true
        }

        // MARK: Parser visualization

        /// Parser annotations are temporary layout attributes. They never enter
        /// text storage, so syntax highlighting, undo and file output remain
        /// unchanged.
        func refreshParserVisualization() {
            guard !isProcessingCharacterEdit else { return }
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
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(selection)
            textView.scrollRangeToVisible(selection)
            updateCursorLocation()
            model.acknowledgeRevealRequest(id: request.id)
        }

        /// Scrolls the source editor to the line the user is reading in the
        /// preview. The caret is deliberately left alone: browsing the preview
        /// must not move the insertion point or steal first responder.
        func fulfillEditorScrollRequest() {
            guard let request = model.editorScrollRequest,
                  request.id != handledScrollID,
                  let textView else { return }
            handledScrollID = request.id
            defer { model.acknowledgeEditorScrollRequest(id: request.id) }

            let length = textView.textStorage?.length ?? 0
            let location = min(max(model.lineStart(atLine: request.line), 0), length)
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let scrollView = textView.enclosingScrollView else {
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
                return
            }

            let lineRange = (textView.string as NSString).lineRange(
                for: NSRange(location: location, length: 0))
            layoutManager.ensureLayout(for: textContainer)
            var rect: NSRect
            if lineRange.length > 0 {
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: lineRange, actualCharacterRange: nil)
                rect = layoutManager.boundingRect(forGlyphRange: glyphRange,
                                                  in: textContainer)
            } else {
                rect = layoutManager.extraLineFragmentRect
            }
            rect.origin.y += textView.textContainerInset.height

            let clipView = scrollView.contentView
            // Leave a little context above the target line instead of pinning
            // it to the very top edge.
            let y = rect.minY - clipView.bounds.height * 0.12
            let maximum = max(0, textView.frame.height - clipView.bounds.height)
            clipView.scroll(to: NSPoint(
                x: clipView.bounds.origin.x,
                y: min(max(0, y), maximum)))
            scrollView.reflectScrolledClipView(clipView)
        }

        func fulfillSourceReplacementRequest() {
            guard let request = model.sourceReplacementRequest,
                  request.id != handledReplacementID,
                  let textView else { return }
            handledReplacementID = request.id
            guard request.revision == model.documentTextGeneration else {
                model.acknowledgeSourceReplacement(id: request.id)
                return
            }
            let length = textView.textStorage?.length ?? 0
            let range = request.range.map { NSRange(location: $0.location, length: $0.length) }
                ?? NSRange(location: 0, length: length)
            guard NSMaxRange(range) <= length else {
                model.acknowledgeSourceReplacement(id: request.id)
                return
            }
            textView.window?.makeFirstResponder(textView)
            textView.insertText(request.text, replacementRange: range)
            model.acknowledgeSourceReplacement(id: request.id)
        }

        private func clearParserVisualization() {
            guard displayedVisualization != nil else { return }
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
                        let validRange = NSIntersectionRange(
                            effectiveRange, NSRange(location: 0, length: length))
                        layoutManager.removeTemporaryAttribute(key, forCharacterRange: validRange)
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
