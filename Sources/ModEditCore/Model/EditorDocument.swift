import Foundation

/// The persisted document state: text, encoding, line index and format.
///
/// ## Why this type is not an `NSDocument`
///
/// `NSDocument` owns the window, save panels, undo integration and the *actual*
/// write to disk. This type owns only the mutable text buffer. Keeping the two
/// apart means the buffer can stay a small, lock-protected, `Sendable` value
/// store that is safe to snapshot from the background thread `NSDocument` uses
/// for saving, while all AppKit state stays on the main actor in
/// `ModEditDocument`.
///
/// ## Locking invariant
///
/// Every field below is read and written while `lock` is held. A snapshot (text,
/// encoding, BOM and generation) is therefore captured atomically: the encoded
/// bytes can never pair older text with a newer generation, or vice versa.
///
/// Observers are always invoked *after* the lock is released. This avoids
/// re-entrancy and lets an observer publish UI state or schedule main-actor work
/// without deadlocking.
final class EditorDocument: @unchecked Sendable {

    /// A consistent copy of the current document state.
    struct Content: Sendable {
        var text: String
        var encoding: String.Encoding
        var hasUTF8BOM: Bool
        var format: any DocumentFormat
    }

    /// An immutable copy of exactly what must be written to disk.
    ///
    /// `generation` identifies the edit state the text was taken from. A save
    /// completion records this value, so a write that was overtaken by newer
    /// edits cannot mark those edits clean.
    struct Snapshot: Sendable {
        let text: String
        let encoding: String.Encoding
        let hasUTF8BOM: Bool
        let generation: UInt64
    }

    private let lock = NSLock()
    /// The formats this document may use. Injected so tests (and future
    /// user-defined formats) do not have to mutate a global singleton.
    let registry: FormatRegistry
    private var textStorage: NSMutableString
    private var encoding: String.Encoding
    private var hasUTF8BOM: Bool
    private var format: any DocumentFormat
    private var generation: UInt64 = 0
    private var savedGeneration: UInt64 = 0
    private var saveObserver: (@Sendable (UInt64) -> Void)?
    private var externalChangeObserver: (@Sendable (UInt64) -> Void)?
    /// Single source of truth for line starts, shared by the status bar and gutter.
    private var lineIndex: LineIndex

    /// A thread-safe copy of the current content.
    var content: Content {
        lock.withLock {
            Content(text: String(textStorage), encoding: encoding,
                    hasUTF8BOM: hasUTF8BOM, format: format)
        }
    }

    var text: String { lock.withLock { String(textStorage) } }
    /// UTF-16 length without materialising the text.
    var textLength: Int { lock.withLock { textStorage.length } }

    /// A text snapshot only if the document is within `limit` UTF-16 units.
    ///
    /// The length check and the copy happen under the same lock, so a preview
    /// can never observe a short document and then copy a grown one. Returning
    /// `nil` lets the caller skip a whole-document copy for very large files.
    func textSnapshot(upTo limit: Int) -> String? {
        lock.withLock {
            guard textStorage.length <= limit else { return nil }
            return String(textStorage)
        }
    }
    var textGeneration: UInt64 { lock.withLock { generation } }
    var isDirty: Bool { lock.withLock { generation != savedGeneration } }
    var currentFormat: any DocumentFormat { lock.withLock { format } }

    /// Number of logical lines, at least one.
    var numberOfLines: Int { lock.withLock { lineIndex.lineCount } }

    /// One-based line and column for a UTF-16 offset, clamped to the document.
    func lineAndColumn(at location: Int) -> (line: Int, column: Int) {
        lock.withLock {
            lineIndex.lineAndColumn(at: min(max(location, 0), textStorage.length))
        }
    }

    /// Whether `location` is the start of a logical line.
    func isLineStart(at location: Int) -> Bool {
        lock.withLock {
            guard location >= 0, location <= textStorage.length else { return false }
            return lineIndex.isLineStart(at: location)
        }
    }

    /// A new, empty document using `registry`'s fallback format.
    init(registry: FormatRegistry = .standard) {
        self.registry = registry
        textStorage = NSMutableString()
        encoding = .utf8
        hasUTF8BOM = false
        format = registry.fallback
        lineIndex = LineIndex()
    }

    /// Atomically captures the text, encoding, BOM and edit generation.
    ///
    /// This is the only method that should be used to produce bytes for saving.
    /// Reading `content` and `textGeneration` separately would allow an edit
    /// between the two reads to make the snapshot internally inconsistent.
    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(text: String(textStorage),
                     encoding: encoding,
                     hasUTF8BOM: hasUTF8BOM,
                     generation: generation)
        }
    }

    // MARK: Loading and mutation

    /// Replaces the entire buffer after a decode and marks it saved.
    ///
    /// Used when opening a file and by Revert. Notifies external observers so an
    /// existing text view can pull in the new contents.
    func load(_ decoded: TextIO.Decoded, format newFormat: any DocumentFormat) {
        let result = lock.withLock { () -> (observer: (@Sendable (UInt64) -> Void)?, generation: UInt64) in
            textStorage.setString(decoded.text)
            encoding = decoded.encoding
            hasUTF8BOM = decoded.hasUTF8BOM
            format = newFormat
            lineIndex.rebuild(from: decoded.text)
            generation &+= 1
            savedGeneration = generation
            return (externalChangeObserver, generation)
        }
        result.observer?(result.generation)
    }

    @discardableResult
    func replaceText(in range: NSRange, with replacement: String) -> UInt64 {
        lock.withLock {
            precondition(range.location >= 0 && NSMaxRange(range) <= textStorage.length,
                         "Edit range is outside the document")
            textStorage.replaceCharacters(in: range, with: replacement)
            let delta = (replacement as NSString).length - range.length
            lineIndex.apply(editIn: range, delta: delta, in: textStorage)
            generation &+= 1
            return generation
        }
    }

    /// Replaces the whole text programmatically (tests and external reloads).
    func setText(_ text: String) {
        let result = lock.withLock { () -> (observer: (@Sendable (UInt64) -> Void)?, generation: UInt64) in
            textStorage.setString(text)
            lineIndex.rebuild(from: text)
            generation &+= 1
            return (externalChangeObserver, generation)
        }
        result.observer?(result.generation)
    }

    func setFormat(_ newFormat: any DocumentFormat) { lock.withLock { format = newFormat } }

    // MARK: Observers

    func setSaveObserver(_ observer: (@Sendable (UInt64) -> Void)?) {
        lock.withLock { saveObserver = observer }
    }

    /// Called after a whole-buffer replacement (open or revert), not after
    /// ordinary typing.
    func setExternalChangeObserver(_ observer: (@Sendable (UInt64) -> Void)?) {
        lock.withLock { externalChangeObserver = observer }
    }

    /// Records a write that has actually completed.
    ///
    /// `savedGeneration` only moves forward, so a late completion for an older
    /// snapshot cannot hide a newer unsaved edit.
    func recordSuccessfulWrite(generation writtenGeneration: UInt64) {
        let observer = lock.withLock { () -> (@Sendable (UInt64) -> Void)? in
            savedGeneration = max(savedGeneration, writtenGeneration)
            return saveObserver
        }
        observer?(writtenGeneration)
    }
}
