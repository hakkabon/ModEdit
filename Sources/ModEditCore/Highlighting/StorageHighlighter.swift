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
    /// Attribute dictionaries are immutable and reused for every token. Creating
    /// them per token made a full pass over a token-dense document allocate
    /// hundreds of thousands of dictionaries.
    private let attributesByKind: [TokenKind: [NSAttributedString.Key: Any]]

    /// Line-aligned scanner snapshots from previous passes. A dirty-line pass
    /// resumes from the nearest one instead of replaying Markdown fence/HTML
    /// state from offset 0.
    private var checkpoints = Tokenizer.Checkpoints()

    /// UTF-16 offset at which the most recent local pass started scanning.
    /// Normally this is the checkpoint before the dirty lines; `0` means no
    /// checkpoint was available. Internal so tests and the benchmark can show
    /// that checkpoints are actually reused.
    private(set) var lastRecoveryStart = 0

    /// Number of cached scanner snapshots. Internal for tests and benchmarks.
    var checkpointCount: Int { checkpoints.count }

    /// Cached snapshot offsets in ascending order. Internal for tests.
    var checkpointOffsets: [Int] { checkpoints.offsets }

    /// - Throws: if a rule's pattern is invalid.
    init(rules: [HighlightRule],
         mode: HighlightingMode = .regularExpressions,
         theme: EditorTheme) throws {
        self.tokenizer = try Tokenizer(rules: rules, mode: mode)
        self.theme = theme
        var attributes: [TokenKind: [NSAttributedString.Key: Any]] = [:]
        for kind in TokenKind.allCases {
            attributes[kind] = theme.attributes(for: kind)
        }
        self.attributesByKind = attributes
    }

    /// Re-highlights the whole lines touched by `requested`.
    ///
    /// The range is clamped to the storage, so a stale range can never raise
    /// `NSRangeException`. Only attributes are modified, never characters, so
    /// this does not register undo actions or alter the text.
    ///
    /// The scanner resumes from the nearest checkpoint at or before the dirty
    /// lines. The text-storage delegate invalidates checkpoints at and after
    /// every character edit, so a resumed state always describes the current
    /// document prefix.
    func apply(to storage: NSTextStorage, in requested: NSRange) {
        let length = storage.length
        guard length > 0 else { return }

        let location = min(max(requested.location, 0), length)
        let end = min(max(NSMaxRange(requested), location), length)

        // `storage.mutableString` exposes the backing characters. Asking for
        // `storage.string` would materialise a complete String copy on every
        // debounced pass, which is unacceptable for large documents.
        let text = storage.mutableString
        let lines = text.lineRange(for: NSRange(location: location, length: end - location))
        var state = checkpoints.state(atOrBefore: lines.location) ?? Tokenizer.State()
        lastRecoveryStart = state.scanLocation
        let tokens = tokenizer.tokens(in: text, range: lines, state: &state,
                                      checkpoints: &checkpoints)
        apply(tokens, to: storage, in: lines)
    }

    /// Re-highlights one line-aligned chunk of a full-document pass.
    ///
    /// `state` carries Markdown fence and HTML tag/comment state between
    /// chunks. Splitting on line boundaries and advancing one `state` in order
    /// makes the pass O(document); applying each chunk independently would
    /// re-scan the document prefix for every chunk. The state at the end of
    /// each chunk is also cached as a checkpoint for later local passes.
    func apply(to storage: NSTextStorage,
               in requested: NSRange,
               state: inout Tokenizer.State) {
        let length = storage.length
        guard length > 0 else { return }

        let location = min(max(requested.location, 0), length)
        let end = min(max(NSMaxRange(requested), location), length)
        guard end > location else { return }

        let text = storage.mutableString
        let lines = text.lineRange(for: NSRange(location: location, length: end - location))
        let tokens = tokenizer.tokens(in: text, range: lines, state: &state)
        checkpoints.record(state, at: state.scanLocation)
        apply(tokens, to: storage, in: lines)
    }

    /// Invalidates snapshots at and after an edit. Call this for every
    /// character edit, before the next local pass.
    func invalidateCheckpoints(from location: Int) {
        checkpoints.invalidate(from: location)
    }

    /// Invalidates every snapshot, for a complete text replacement.
    func invalidateCheckpoints() {
        checkpoints.removeAll()
    }

    private func apply(_ tokens: [Token], to storage: NSTextStorage, in lines: NSRange) {
        storage.beginEditing()
        storage.setAttributes(theme.baseAttributes, range: lines)
        for token in tokens {
            guard let attributes = attributesByKind[token.kind] else { continue }
            storage.addAttributes(attributes, range: token.range)
        }
        storage.endEditing()
    }
}
