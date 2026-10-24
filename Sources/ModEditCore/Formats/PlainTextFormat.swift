import AppKit
import UniformTypeIdentifiers

struct PlainTextFormat: DocumentFormat {
    let id = "plaintext"
    let displayName = "Plain Text"
    let contentTypes: [UTType] = [.plainText, .utf8PlainText]
    let fileExtensions = ["txt", "text", "log"]

    func makeHighlighter() -> (any SyntaxHighlighter)? { nil }
    func makePreviewRenderer() -> (any PreviewRenderer)? { nil }
}
