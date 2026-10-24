import AppKit
import UniformTypeIdentifiers

extension UTType {
    static let latex = UTType(importedAs: "org.tug.tex")
}

struct LaTeXFormat: DocumentFormat {
    let id = "latex"
    let displayName = "LaTeX"
    let contentTypes: [UTType] = [.latex]
    let fileExtensions = ["tex", "sty", "cls", "ltx"]

    func makeHighlighter() -> (any SyntaxHighlighter)? {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.textColor]
        let rules = (try? [
            HighlightRule(#"%.*$"#, [.foregroundColor: NSColor.secondaryLabelColor]),
            HighlightRule(#"\\[a-zA-Z]+"#, [.foregroundColor: NSColor.systemPurple]),
            HighlightRule(#"\$[^$\n]+\$"#, [.foregroundColor: NSColor.systemTeal]),
            HighlightRule(#"\[([^\]\n]+)\]"#, [.foregroundColor: NSColor.systemOrange]),
            HighlightRule(#"\{([^\}\n]+)\}"#, [.foregroundColor: NSColor.systemBlue]),
        ]) ?? []
        return RuleBasedHighlighter(base: base, rules: rules)
    }

    func makePreviewRenderer() -> (any PreviewRenderer)? { LaTeXPreviewRenderer() }
}
