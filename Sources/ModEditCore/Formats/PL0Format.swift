import UniformTypeIdentifiers

/// PL/0 is the first controlled language in the parsing workbench. These rules
/// are presentation only; authoritative tokens come from `PL0Language`.
struct PL0Format: DocumentFormat {
    let id = "pl0"
    let displayName = "PL/0"
    let contentTypes: [UTType] = [.pl0Source]
    let fileExtensions = ["pl0"]

    var highlightRules: [HighlightRule] {
        [
            HighlightRule(#"\b\d+\b"#, .number),
            HighlightRule(#"\b(const|var|procedure|call|begin|end|if|then|while|do|odd)\b"#,
                          .keyword),
            HighlightRule(#"(:=|<=|>=|#|=|<|>|[+\-*/])"#, .operator),
            HighlightRule(#"//[^\r\n]*|/\*[\s\S]*?\*/"#, .comment),
        ]
    }

    func makePreviewRenderer() -> (any PreviewRenderer)? { nil }
}
