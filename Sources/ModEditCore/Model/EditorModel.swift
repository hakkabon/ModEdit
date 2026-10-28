import Combine
import Foundation

/// Main-actor view model for one editor window.
///
/// Publishes a cheap revision counter instead of a complete `String` on every
/// keystroke. Preview and saving request a snapshot only after their debounce
/// or when the document is written.
@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var textRevision: UInt64
    @Published private(set) var format: any DocumentFormat
    @Published private(set) var cursorLine = 1
    @Published private(set) var cursorColumn = 1
    @Published private(set) var isDocumentDirty: Bool
    @Published private(set) var lineCount: Int
    /// Whether the live-preview pane is shown. Owned here rather than in the
    /// view so the window's toolbar can toggle it.
    @Published var showPreview = true

    let tabSize = 4

    /// Called after an edit has been applied to the buffer. The `NSDocument`
    /// shell uses this to record a change for autosave and the window's edited
    /// indicator.
    var onTextChange: (() -> Void)?
    /// Called when the user picks a different format.
    var onFormatChange: ((any DocumentFormat) -> Void)?

    private let document: EditorDocument

    init(document: EditorDocument) {
        self.document = document
        self.textRevision = document.textGeneration
        self.format = document.currentFormat
        self.isDocumentDirty = document.isDirty
        self.lineCount = document.numberOfLines
        document.setSaveObserver { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDocumentState()
            }
        }
        document.setExternalChangeObserver { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAfterExternalChange()
            }
        }
    }

    deinit {
        document.setSaveObserver(nil)
        document.setExternalChangeObserver(nil)
    }

    func textSnapshot() -> String { document.text }

    /// Snapshot for the live preview. Large documents return `nil` instead of
    /// being copied and rendered on every debounce.
    func previewSnapshot(upTo limit: Int) -> String? {
        document.textSnapshot(upTo: limit)
    }

    var documentTextGeneration: UInt64 { document.textGeneration }

    /// Applies one TextKit edit using UTF-16 offsets. `editedRange` is the
    /// post-edit range and `delta` is the change in storage length.
    @discardableResult
    func applyTextEdit(editedRange: NSRange, delta: Int, replacement: String) -> UInt64 {
        let oldLength = editedRange.length - delta
        let oldRange = NSRange(location: editedRange.location, length: oldLength)
        let generation = document.replaceText(in: oldRange, with: replacement)
        textRevision = generation
        lineCount = document.numberOfLines
        isDocumentDirty = document.isDirty
        onTextChange?()
        return generation
    }

    func updateCursor(line: Int, column: Int) {
        cursorLine = max(1, line)
        cursorColumn = max(1, column)
    }

    /// Shared line lookup used by the status bar and the gutter.
    func lineAndColumn(at location: Int) -> (line: Int, column: Int) {
        document.lineAndColumn(at: location)
    }

    /// Refreshes UI state after a document replacement that did not originate
    /// in the text view (for example Revert to Saved).
    func refreshAfterExternalChange() {
        format = document.currentFormat
        textRevision = document.textGeneration
        lineCount = document.numberOfLines
        isDocumentDirty = document.isDirty
    }

    private func refreshDocumentState() {
        isDocumentDirty = document.isDirty
    }

    /// Switches the document's format (highlighting and preview).
    func setFormat(_ newFormat: any DocumentFormat) {
        format = newFormat
        document.setFormat(newFormat)
        onFormatChange?(newFormat)
    }
}

extension EditorModel: LineNumberSource {
    func lineNumber(at location: Int) -> Int {
        document.lineAndColumn(at: location).line
    }

    func isLineStart(at location: Int) -> Bool {
        document.isLineStart(at: location)
    }
}
