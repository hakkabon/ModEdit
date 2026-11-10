import UniformTypeIdentifiers

/// Presentation policy only; authoritative analysis comes from GrammarLanguage.
struct GrammarFormat: DocumentFormat {
    let id = "grammar"
    let displayName = "Grammar"
    let contentTypes: [UTType] = [.grammarSource]
    let fileExtensions = ["bnf", "ebnf", "wsn", "grammar"]
    var highlightRules: [HighlightRule] { [] }
    func makePreviewRenderer() -> (any PreviewRenderer)? { nil }
}
