import Combine
import Foundation
import PL0Language

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
    /// Revision-bound PL/0 problems and recovery markers drawn over the editor.
    @Published private(set) var pl0Visualization: PL0EditorVisualization?
    /// Monotonic request used to reveal workbench items in the source editor.
    @Published private(set) var revealRequest: EditorRevealRequest?
    /// Whether the live-preview pane is shown. Owned here rather than in the
    /// view so the window's toolbar can toggle it.
    @Published var showPreview = true
    /// Whether the experimental parser inspector is visible for PL/0.
    @Published var showWorkbench = true
    /// The last replacement, used by incremental language services. It is not
    /// published separately because every edit also publishes `textRevision`.
    private(set) var lastSourceEdit: SourceEdit?
    private var nextRevealID: UInt64 = 0

    let tabSize = 4
    /// The format catalogue shown in the status-bar picker.
    let registry: FormatRegistry

    /// Called after an edit has been applied to the buffer. The `NSDocument`
    /// shell uses this to record a change for autosave and the window's edited
    /// indicator.
    var onTextChange: (() -> Void)?
    /// Called when the user picks a different format.
    var onFormatChange: ((any DocumentFormat) -> Void)?

    private let document: EditorDocument

    init(document: EditorDocument, registry: FormatRegistry? = nil) {
        self.document = document
        self.registry = registry ?? document.registry
        self.textRevision = document.textGeneration
        self.format = document.currentFormat
        self.isDocumentDirty = document.isDirty
        self.lineCount = document.numberOfLines
        self.lastSourceEdit = nil
        self.pl0Visualization = nil
        self.revealRequest = nil
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
        let baseVersion = document.textGeneration
        let generation = document.replaceText(in: oldRange, with: replacement)
        lastSourceEdit = SourceEdit(
            baseVersion: baseVersion,
            replacedRange: SourceRange(location: oldRange.location, length: oldRange.length),
            replacementLength: (replacement as NSString).length)
        pl0Visualization = nil
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
        lastSourceEdit = nil
        pl0Visualization = nil
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
        if newFormat.id != "pl0" { pl0Visualization = nil }
        document.setFormat(newFormat)
        onFormatChange?(newFormat)
    }

    /// Opens the PL/0 workbench from any document. The toolbar item is a
    /// launcher as well as a visibility toggle, so it must never become a
    /// disabled dead end while another format is selected.
    func activatePL0Workbench() {
        if format.id != "pl0", let pl0 = registry.format(withID: "pl0") {
            setFormat(pl0)
        }
        showWorkbench = true
    }

    /// Accepts only current PL/0 results. This is the final stale-result guard
    /// between the detached parser and TextKit presentation.
    func publishPL0Visualization(_ result: ParseResult) {
        guard format.id == "pl0", result.version == textRevision else { return }
        pl0Visualization = PL0EditorVisualization(result: result)
    }

    func revealSourceRange(_ range: SourceRange) {
        nextRevealID &+= 1
        revealRequest = EditorRevealRequest(id: nextRevealID, range: range)
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
