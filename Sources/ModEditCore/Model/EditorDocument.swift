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

    /// Everything that is saved, plus the chosen format.
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
    }

    static var readableContentTypes: [UTType] { FormatRegistry.standard.readableContentTypes }
    static var writableContentTypes: [UTType] { readableContentTypes }

    private let lock = NSLock()
    private var storage: Content

    /// A thread-safe copy of the current content.
    var content: Content { lock.withLock { storage } }

    /// A new, empty plain-text document.
    init() {
        storage = Content(text: "", encoding: .utf8, hasUTF8BOM: false,
                          format: FormatRegistry.standard.fallback)
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoded = try TextIO.decode(data)
        storage = Content(text: decoded.text,
                          encoding: decoded.encoding,
                          hasUTF8BOM: decoded.hasUTF8BOM,
                          format: FormatRegistry.standard.format(for: configuration.contentType))
    }

    // MARK: Mutation (called by EditorModel)

    func setText(_ text: String) { lock.withLock { storage.text = text } }
    func setFormat(_ format: any DocumentFormat) { lock.withLock { storage.format = format } }

    // MARK: ReferenceFileDocument

    func snapshot(contentType: UTType) throws -> Snapshot {
        let current = content
        return Snapshot(text: current.text,
                        encoding: current.encoding,
                        hasUTF8BOM: current.hasUTF8BOM)
    }

    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try TextIO.encode(snapshot.text,
                                     as: snapshot.encoding,
                                     withUTF8BOM: snapshot.hasUTF8BOM)
        return FileWrapper(regularFileWithContents: data)
    }
}
