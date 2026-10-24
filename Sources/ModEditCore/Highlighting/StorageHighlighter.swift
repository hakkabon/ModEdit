import AppKit

/// Applies a format's highlighting to an `NSTextStorage`.
///
/// Create one per format and keep it: construction compiles every regular
/// expression, which is far too expensive to repeat on each keystroke (the
/// previous design rebuilt all rules for every highlight pass).
@MainActor
final class StorageHighlighter {
    private let tokenizer: Tokenizer
    private let theme: EditorTheme

    /// - Throws: if a rule's pattern is invalid.
    init(rules: [HighlightRule], theme: EditorTheme) throws {
        self.tokenizer = try Tokenizer(rules: rules)
        self.theme = theme
    }

    /// Re-highlights the whole lines touched by `requested`.
    ///
    /// The range is clamped to the storage, so a stale range can never raise
    /// `NSRangeException`. Only attributes are modified, never characters, so
    /// this does not register undo actions or alter the text.
    func apply(to storage: NSTextStorage, in requested: NSRange) {
        let length = storage.length
        guard length > 0 else { return }

        let location = min(max(requested.location, 0), length)
        let end = min(max(NSMaxRange(requested), location), length)

        let text = storage.string
        let lines = (text as NSString).lineRange(for: NSRange(location: location, length: end - location))
        let tokens = tokenizer.tokens(in: text, range: lines)

        storage.beginEditing()
        storage.setAttributes(theme.baseAttributes, range: lines)
        for token in tokens {
            storage.addAttributes(theme.attributes(for: token.kind), range: token.range)
        }
        storage.endEditing()
    }
}
