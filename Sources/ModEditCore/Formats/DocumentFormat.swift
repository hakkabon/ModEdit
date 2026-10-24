import AppKit
import UniformTypeIdentifiers

protocol DocumentFormat: Sendable {
    var id: String { get }
    var displayName: String { get }
    var contentTypes: [UTType] { get }
    var fileExtensions: [String] { get }

    func makeHighlighter() -> (any SyntaxHighlighter)?
    func makePreviewRenderer() -> (any PreviewRenderer)?
}

protocol SyntaxHighlighter {
    func highlight(_ storage: NSTextStorage, in requestedRange: NSRange)
}

protocol PreviewRenderer: Sendable {
    func renderHTML(from source: String) async throws -> String
}

@MainActor
final class FormatRegistry {
    static let shared = FormatRegistry()
    private var formats: [any DocumentFormat] = []

    func register(_ format: any DocumentFormat) { formats.append(format) }

    func format(for type: UTType) -> any DocumentFormat {
        formats.first { f in f.contentTypes.contains { type.conforms(to: $0) } }
            ?? PlainTextFormat()
    }
}
