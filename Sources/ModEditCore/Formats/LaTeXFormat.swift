import UniformTypeIdentifiers

struct LaTeXFormat: DocumentFormat {
    let id = "latex"
    let displayName = "LaTeX"
    let contentTypes: [UTType] = [.latex]
    let fileExtensions = ["tex", "sty", "cls", "ltx"]

    /// Lowest priority first. Comments come *last*: anything inside a `%`
    /// comment must look like a comment, not like a command or an argument.
    var highlightRules: [HighlightRule] {
        [
            HighlightRule(#"\{([^\}\n]+)\}"#, .argument),
            HighlightRule(#"\[([^\]\n]+)\]"#, .optionalArgument),
            HighlightRule(#"\\[a-zA-Z]+"#, .command),
            HighlightRule(#"\$[^$\n]+\$"#, .math),
            HighlightRule(#"(?<!\\)%.*$"#, .comment),
        ]
    }

    func makePreviewRenderer() -> (any PreviewRenderer)? { LaTeXPreviewRenderer() }
}
