import AppKit
import UniformTypeIdentifiers

struct HTMLFormat: DocumentFormat {
    let id = "html"
    let displayName = "HTML"
    let contentTypes: [UTType] = [.html]
    let fileExtensions = ["html", "htm", "xhtml"]

    func makeHighlighter() -> (any SyntaxHighlighter)? {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.textColor]
        let rules = (try? [
            HighlightRule(#"<!--.*?-->"#, [.foregroundColor: NSColor.secondaryLabelColor]),
            HighlightRule(#"<[^>]+>"#, [.foregroundColor: NSColor.systemBlue]),
            HighlightRule(#"[a-zA-Z-]+="#, [.foregroundColor: NSColor.systemPurple]),
            HighlightRule(#""[^"]*""#, [.foregroundColor: NSColor.systemOrange]),
        ]) ?? []
        return RuleBasedHighlighter(base: base, rules: rules)
    }

    func makePreviewRenderer() -> (any PreviewRenderer)? { HTMLPreviewRenderer() }
}
