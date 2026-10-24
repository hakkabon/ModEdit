import AppKit
import UniformTypeIdentifiers

struct MarkdownFormat: DocumentFormat {
    let id = "markdown"
    let displayName = "Markdown"
    let contentTypes: [UTType] = [.markdown]
    let fileExtensions = ["md", "markdown", "mdown"]

    func makeHighlighter() -> (any SyntaxHighlighter)? {
        let bold = NSFontManager.shared.convert(
            .monospacedSystemFont(ofSize: 13, weight: .regular), toHaveTrait: .boldFontMask)
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.textColor]
        let rules = (try? [
            HighlightRule(#"^\s{0,3}#{1,6}\s.*$"#, [.foregroundColor: NSColor.systemBlue, .font: bold]),
            HighlightRule(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, [.font: bold]),
            HighlightRule(#"`[^`\n]+`"#, [.foregroundColor: NSColor.systemPink]),
            HighlightRule(#"\[[^\]\n]*\]\([^)\n]*\)"#,
                          [.foregroundColor: NSColor.linkColor,
                           .underlineStyle: NSUnderlineStyle.single.rawValue]),
            HighlightRule(#"^\s*>\s?.*$"#, [.foregroundColor: NSColor.secondaryLabelColor]),
            HighlightRule(#"^\s*[-*+]\s"#, [.foregroundColor: NSColor.systemOrange]),
        ]) ?? []
        return RuleBasedHighlighter(base: base, rules: rules)
    }

    func makePreviewRenderer() -> (any PreviewRenderer)? { MarkdownPreviewRenderer() }
}
