import UniformTypeIdentifiers

struct MarkdownFormat: DocumentFormat {
    let id = "markdown"
    let displayName = "Markdown"
    let contentTypes: [UTType] = [.markdownText]
    let fileExtensions = ["md", "markdown", "mdown"]

    /// Lowest priority first; code spans last so their colour wins over
    /// anything that happens to match inside them.
    var highlightRules: [HighlightRule] {
        [
            HighlightRule(#"^\s{0,3}#{1,6}\s.*$"#, .heading),
            HighlightRule(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, .strong),
            HighlightRule(#"\[[^\]\n]*\]\([^)\n]*\)"#, .link),
            HighlightRule(#"^\s*>\s?.*$"#, .quote),
            HighlightRule(#"^\s*[-*+]\s"#, .listMarker),
            HighlightRule(#"`[^`\n]+`"#, .code),
        ]
    }

    func makePreviewRenderer() -> (any PreviewRenderer)? { MarkdownPreviewRenderer() }
}
