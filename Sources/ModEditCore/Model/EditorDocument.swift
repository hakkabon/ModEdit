import SwiftUI
import UniformTypeIdentifiers

/// The persisted document: text, encoding and format.
///
/// ## Why this type looks the way it does
///
/// `ReferenceFileDocument` requires conforming types to be `Sendable`, and
/// SwiftUI calls `snapshot` and `fileWrapper` on different threads (Apple:
/// "don't perform serialization on the main actor"). The document therefore:
///
/// * keeps its state behind a lock (`@unchecked Sendable` is justified by that
///   lock being the *only* access path);
/// * hands SwiftUI a **value-type snapshot**, not itself. Returning the live
///   model, as the previous version did, races with ongoing typing.
///
/// UI state (published text, the preview) lives in the main-actor `EditorModel`,
/// which writes edits back here.
final class EditorDocument: ReferenceFileDocument, @unchecked Sendable {

    /// A consistent copy of the current document state.
    struct Content: Sendable {
        var text: String
        var encoding: String.Encoding
        var hasUTF8BOM: Bool
        var format: any DocumentFormat
    }

    /// An immutable copy of what must be written to disk.
    struct Snapshot: Sendable {
        let text: String
        let encoding: String.Encoding
        let hasUTF8BOM: Bool
        let generation: UInt64
    }

    static var readableContentTypes: [UTType] { FormatRegistry.standard.readableContentTypes }
    static var writableContentTypes: [UTType] { readableContentTypes }

    private let lock = NSLock()
    private var textStorage: NSMutableString
    private var encoding: String.Encoding
    private var hasUTF8BOM: Bool
    private var format: any DocumentFormat
    private var generation: UInt64 = 0
    private var savedGeneration: UInt64 = 0
    private var saveObserver: (@Sendable (UInt64) -> Void)?
    private var lineCount: Int

    /// A thread-safe copy of the current content.
    var content: Content {
        lock.withLock {
            Content(text: String(textStorage), encoding: encoding,
                    hasUTF8BOM: hasUTF8BOM, format: format)
        }
    }

    var text: String { lock.withLock { String(textStorage) } }
    var textGeneration: UInt64 { lock.withLock { generation } }
    var isDirty: Bool { lock.withLock { generation != savedGeneration } }
    var numberOfLines: Int { lock.withLock { lineCount } }

    /// A new, empty plain-text document.
    init() {
        textStorage = NSMutableString()
        encoding = .utf8
        hasUTF8BOM = false
        format = FormatRegistry.standard.fallback
        lineCount = 1
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoded = try TextIO.decode(data)
        textStorage = NSMutableString(string: decoded.text)
        encoding = decoded.encoding
        hasUTF8BOM = decoded.hasUTF8BOM
        format = FormatRegistry.standard.format(for: configuration.contentType)
        lineCount = Self.countLines(in: decoded.text)
    }

    // MARK: Mutation (called by EditorModel)

    @discardableResult
    func replaceText(in range: NSRange, with replacement: String) -> UInt64 {
        lock.withLock {
            precondition(range.location >= 0 && NSMaxRange(range) <= textStorage.length,
                         "Edit range is outside the document")
            let removed = textStorage.substring(with: range)
            lineCount += replacement.filter { $0 == "\n" }.count
                - removed.filter { $0 == "\n" }.count
            textStorage.replaceCharacters(in: range, with: replacement)
            generation &+= 1
            return generation
        }
    }

    func setText(_ text: String) {
        lock.withLock {
            textStorage.setString(text)
            lineCount = Self.countLines(in: text)
            generation &+= 1
        }
    }

    func setFormat(_ newFormat: any DocumentFormat) { lock.withLock { format = newFormat } }

    private static func countLines(in text: String) -> Int {
        text.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    func setSaveObserver(_ observer: (@Sendable (UInt64) -> Void)?) {
        lock.withLock { saveObserver = observer }
    }

    /// Records a successful write without clearing a newer unsaved edit.
    func recordSuccessfulWrite(generation writtenGeneration: UInt64) {
        let observer = lock.withLock { () -> (@Sendable (UInt64) -> Void)? in
            savedGeneration = max(savedGeneration, writtenGeneration)
            return saveObserver
        }
        observer?(writtenGeneration)
    }

    // MARK: ReferenceFileDocument

    func snapshot(contentType: UTType) throws -> Snapshot {
        let current = content
        return Snapshot(text: current.text,
                        encoding: current.encoding,
                        hasUTF8BOM: current.hasUTF8BOM,
                        generation: textGeneration)
    }

    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try TextIO.encode(snapshot.text,
                                     as: snapshot.encoding,
                                     withUTF8BOM: snapshot.hasUTF8BOM)
        recordSuccessfulWrite(generation: snapshot.generation)
        return FileWrapper(regularFileWithContents: data)
    }
}
