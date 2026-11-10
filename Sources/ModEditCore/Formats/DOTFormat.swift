import UniformTypeIdentifiers

/// Presentation policy only; authoritative analysis comes from DOTLanguage.
struct DOTFormat: DocumentFormat {
    let id = "dot"
    let displayName = "Graphviz DOT"
    let contentTypes: [UTType] = [.dotSource]
    let fileExtensions = ["dot", "gv"]
    var highlightRules: [HighlightRule] { [] }
    func makePreviewRenderer() -> (any PreviewRenderer)? { nil }
}
