import Combine
import Foundation

/// Main-actor view model for one editor window.
///
/// Publishes a cheap revision counter instead of a complete `String` on every
/// keystroke. Preview and saving request a snapshot only after their debounce
/// or when SwiftUI asks for a file snapshot.
@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var textRevision: UInt64
    @Published private(set) var format: any DocumentFormat
    @Published private(set) var cursorLine = 1
    @Published private(set) var cursorColumn = 1
    @Published private(set) var isDocumentDirty: Bool
    @Published private(set) var lineCount: Int

    let tabSize = 4

    private let document: EditorDocument

    init(document: EditorDocument) {
        let content = document.content
        self.document = document
        self.textRevision = document.textGeneration
        self.format = content.format
        self.isDocumentDirty = document.isDirty
        self.lineCount = document.numberOfLines
        document.setSaveObserver { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDocumentState()
            }
        }
    }

    deinit { document.setSaveObserver(nil) }

    func textSnapshot() -> String { document.text }

    var documentTextGeneration: UInt64 { document.textGeneration }

    /// Applies one TextKit edit using UTF-16 offsets. `editedRange` is the
    /// post-edit range and `delta` is the change in storage length.
    @discardableResult
    func applyTextEdit(editedRange: NSRange, delta: Int, replacement: String) -> UInt64 {
        let oldLength = editedRange.length - delta
        let oldRange = NSRange(location: editedRange.location, length: oldLength)
        // ReferenceFileDocument uses this publisher to schedule autosave and
        // update the edited-state indicator in the window title.
        document.objectWillChange.send()
        let generation = document.replaceText(in: oldRange, with: replacement)
        textRevision = generation
        lineCount = document.numberOfLines
        isDocumentDirty = document.isDirty
        return generation
    }

    func updateCursor(line: Int, column: Int) {
        cursorLine = max(1, line)
        cursorColumn = max(1, column)
    }

    private func refreshDocumentState() {
        isDocumentDirty = document.isDirty
    }

    /// Switches the document's format (highlighting and preview).
    func setFormat(_ newFormat: any DocumentFormat) {
        format = newFormat
        document.setFormat(newFormat)
    }
}
