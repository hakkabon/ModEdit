import UniformTypeIdentifiers

struct PlainTextFormat: DocumentFormat {
    let id = "plaintext"
    let displayName = "Plain Text"
    let contentTypes: [UTType] = [.plainText, .utf8PlainText]
    let fileExtensions = ["txt", "text", "log"]

    var highlightRules: [HighlightRule] { [] }
    func makePreviewRenderer() -> (any PreviewRenderer)? { nil }
}
