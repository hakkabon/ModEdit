import UniformTypeIdentifiers

struct HTMLFormat: DocumentFormat {
    let id = "html"
    let displayName = "HTML"
    let contentTypes: [UTType] = [.html]
    let fileExtensions = ["html", "htm", "xhtml"]

    /// Lowest priority first; comments last.
    ///
    /// Known limitation: the attribute-name rule matches `name=` anywhere, not
    /// only inside tags, and nothing here understands multi-line constructs
    /// (see "Known limitations" in the README).
    var highlightRules: [HighlightRule] {
        [
            HighlightRule(#"<[^>]+>"#, .tag),
            HighlightRule(#"[a-zA-Z-]+(?==)"#, .attributeName),
            HighlightRule(#""[^"\n]*""#, .string),
            HighlightRule(#"<!--.*?-->"#, .comment),
        ]
    }

    func makePreviewRenderer() -> (any PreviewRenderer)? { HTMLPreviewRenderer() }
}
