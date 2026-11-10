import UniformTypeIdentifiers

/// Presentation policy only; authoritative analysis comes from CSSLanguage.
struct CSSFormat: DocumentFormat {
    let id = "css"
    let displayName = "CSS"
    let contentTypes: [UTType] = [.cssText]
    let fileExtensions = ["css"]
    var highlightRules: [HighlightRule] { [] }
    func makePreviewRenderer() -> (any PreviewRenderer)? { nil }
}
