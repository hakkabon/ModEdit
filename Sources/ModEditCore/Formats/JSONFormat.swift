import UniformTypeIdentifiers

/// Presentation policy only; authoritative analysis comes from JSONLanguage.
struct JSONFormat: DocumentFormat {
    let id = "json"
    let displayName = "JSON"
    let contentTypes: [UTType] = [.json]
    let fileExtensions = ["json"]
    var highlightRules: [HighlightRule] { [] }
    func makePreviewRenderer() -> (any PreviewRenderer)? { nil }
}
