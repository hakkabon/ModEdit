import Combine
import Foundation

/// Main-actor view model for one editor window.
///
/// Owns the *published* state SwiftUI observes (the text for the preview, the
/// current format) and forwards every change to the thread-safe
/// `EditorDocument` that gets saved.
///
/// Note: the `NSTextView`'s text storage remains the live source of truth while
/// typing; `text` here is a copy synchronised on each edit (see "Known
/// limitations" in the README for the cost of that).
@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var text: String
    @Published private(set) var format: any DocumentFormat

    private let document: EditorDocument

    init(document: EditorDocument) {
        let content = document.content
        self.document = document
        self.text = content.text
        self.format = content.format
    }

    /// Called by the text view after every user edit.
    func textDidChange(_ newText: String) {
        text = newText
        document.setText(newText)
    }

    /// Switches the document's format (highlighting and preview).
    func setFormat(_ newFormat: any DocumentFormat) {
        format = newFormat
        document.setFormat(newFormat)
    }
}
