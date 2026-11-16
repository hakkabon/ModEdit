import AppKit
import Grammar
import Railroad

struct GrammarPreviewRenderer: PreviewRenderer {
    func renderHTML(from source: String) async throws -> String {
        guard source.utf8.count <= 8_192 else {
            return PreviewPage.wrap(body: "<p>Railroad preview is limited to 8 KiB of grammar source.</p>")
        }
        let parser = GrammarParser(grammar: source, reportsDiagnostics: false)
        let syntax = parser.parse()
        if !parser.diagnostics.isEmpty {
            let problems = parser.diagnostics.map {
                "<li>\(HTMLEscaping.escape($0.message))</li>"
            }.joined()
            return PreviewPage.wrap(body: "<h2>Grammar diagnostics</h2><ul>\(problems)</ul>")
        }
        guard case .syntax(let items) = syntax else {
            return PreviewPage.wrap(body: "<p>No grammar rules to display.</p>")
        }
        var diagrams: [String] = []
        for item in items {
            try Task.checkCancellation()
            guard case .production(let name, let expression) = item else { continue }
            let model = diagram(expression)
            let image = Railroad.renderImage(model, scale: 1)
            let title = HTMLEscaping.escape(name)
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                diagrams.append("<h2>\(title)</h2><p>Could not render this rule.</p>")
                continue
            }
            diagrams.append("<h2>\(title)</h2><img alt=\"Railroad diagram for \(title)\" src=\"data:image/png;base64,\(png.base64EncodedString())\">")
        }
        return PreviewPage.wrap(body: diagrams.isEmpty
                                ? "<p>No grammar rules to display.</p>"
                                : diagrams.joined(separator: "\n"))
    }

    private func diagram(_ expression: BnfExpression) -> any DiagramConvertible {
        switch expression {
        case .terminal(let name): Railroad.Terminal(name)
        case .nonterminal(let name): Railroad.NonTerminal(name)
        case .sequence(let items), .syntax(let items):
            Series(elements: items.map { diagram($0).toGraphic() })
        case .alternative(let items): Railroad.choice(items.map(diagram))
        case .optional(let child): Railroad.optional(diagram(child), false)
        case .repetition(let child): Railroad.zeroOrMore(diagram(child))
        case .repetitionOnePlus(let child): Railroad.oneOrMore(diagram(child))
        case .production(_, let child), .grouping(let child): diagram(child)
        case .empty, .start: Railroad.skip()
        case .range(_, let lower, let upper): Railroad.Special("\(lower)…\(upper)")
        case .regex(_, let pattern): Railroad.Special("/\(pattern)/")
        case .list(_, let values):
            Railroad.choice(values.map { Railroad.Terminal($0) }, centerIndex: 0)
        }
    }
}
