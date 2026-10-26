import UniformTypeIdentifiers

struct HTMLFormat: DocumentFormat {
    let id = "html"
    let displayName = "HTML"
    let contentTypes: [UTType] = [.html]
    let fileExtensions = ["html", "htm", "xhtml"]
    let highlightingMode: HighlightingMode = .html

    /// Attribute rules are combined with the stateful tag/comment scanner.
    var highlightRules: [HighlightRule] {
        [
            HighlightRule(#"[a-zA-Z-]+(?==)"#, .attributeName),
            HighlightRule(#""[^"\n]*""#, .string),
        ]
    }

    func makePreviewRenderer() -> (any PreviewRenderer)? { HTMLPreviewRenderer() }
}
