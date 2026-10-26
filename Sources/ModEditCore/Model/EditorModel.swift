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

    private let document: EditorDocument

    init(document: EditorDocument) {
        let content = document.content
        self.document = document
        self.textRevision = document.textGeneration
        self.format = content.format
    }

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
        return generation
    }

    /// Switches the document's format (highlighting and preview).
    func setFormat(_ newFormat: any DocumentFormat) {
        format = newFormat
        document.setFormat(newFormat)
    }
}
