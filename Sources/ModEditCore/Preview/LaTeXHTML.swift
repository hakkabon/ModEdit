import Foundation

/// A lightweight LaTeX preview: it *renders* common constructs differently from
/// the ASCII source (the editor's headline feature) without being a TeX engine.
///
/// Supported: `\section`/`\subsection`/`\subsubsection`, `\textbf`, `\emph`,
/// `\textit`, `\texttt`, `\\`, `--`/`---`, `~`, `%` comments, inline `$...$`
/// and display `$$...$$` math with Greek letters and common operators
/// (see `symbols`), and `^`/`_` super- and subscripts.
///
/// Not supported: environments, `\frac`, `\sqrt`, macros, packages, citations.
/// For typeset-quality maths, bundle KaTeX (see the README roadmap).
///
/// Everything is HTML-escaped first, so source such as `a < b` or `<script>`
/// is displayed, never interpreted.
enum LaTeXHTML {

    /// `\name` -> symbol.
    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "varepsilon": "ε", "theta": "θ", "lambda": "λ", "mu": "μ", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Pi": "Π",
        "Sigma": "Σ", "Phi": "Φ", "Omega": "Ω",
        "times": "×", "cdot": "·", "pm": "±", "infty": "∞", "sum": "∑",
        "prod": "∏", "int": "∫", "partial": "∂", "nabla": "∇",
        "leq": "≤", "geq": "≥", "neq": "≠", "approx": "≈", "equiv": "≡",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒",
        "Leftarrow": "⇐", "in": "∈", "subset": "⊂", "forall": "∀", "exists": "∃",
        "ldots": "…", "dots": "…",
    ]

    private static let blockBreak = "\u{E001}"

    static func render(_ source: String) -> String {
        var text = source

        // With a preamble, preview only the document body.
        if let begin = text.range(of: "\\begin{document}") {
            text = String(text[begin.upperBound...])
            if let end = text.range(of: "\\end{document}") {
                text = String(text[..<end.lowerBound])
            }
        }

        // Strip comments (an unescaped % to end of line), then escape.
        text = text.replacingOccurrences(of: #"(?m)(?<!\\)%.*$"#, with: "", options: .regularExpression)
        text = HTMLEscaping.escape(text)

        // Sectioning commands become headings set apart by blank lines.
        text = text.replacingMatches(
            of: #"(?m)^[ \t]*\\(section|subsection|subsubsection)\*?\{([^}\n]*)\}"#
        ) { groups in
            let level = groups[1] == "section" ? 2 : (groups[1] == "subsection" ? 3 : 4)
            return "\n\n<h\(level)>\(inline(groups[2]))</h\(level)>\n\n"
        }

        let blocks = text
            .replacingOccurrences(of: #"\n\s*\n"#, with: blockBreak, options: .regularExpression)
            .components(separatedBy: blockBreak)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return blocks
            .map { $0.hasPrefix("<h") ? $0 : "<p>\(inline($0))</p>" }   // escaped text never starts with "<"
            .joined(separator: "\n")
    }

    /// Inline constructs. Input is already HTML-escaped.
    private static func inline(_ text: String) -> String {
        var s = text
        s = s.replacingMatches(of: #"(?s)\$\$(.+?)\$\$"#) { "<span class=\"math display\">\(math($0[1]))</span>" }
        s = s.replacingMatches(of: #"\$([^$\n]+)\$"#) { "<span class=\"math\">\(math($0[1]))</span>" }
        s = s.replacingMatches(of: #"\\textbf\{([^{}]*)\}"#) { "<strong>\($0[1])</strong>" }
        s = s.replacingMatches(of: #"\\(?:emph|textit)\{([^{}]*)\}"#) { "<em>\($0[1])</em>" }
        s = s.replacingMatches(of: #"\\texttt\{([^{}]*)\}"#) { "<code>\($0[1])</code>" }
        s = s.replacingOccurrences(of: #"\\\\"#, with: "<br>", options: .regularExpression)
        s = s.replacingMatches(of: #"\\([A-Za-z]+)"#) { symbols[$0[1]] ?? $0[0] }
        s = s.replacingOccurrences(of: "---", with: "\u{2014}")
        s = s.replacingOccurrences(of: "--", with: "\u{2013}")
        return s.replacingOccurrences(of: "~", with: "\u{00A0}")
    }

    /// Math content: symbols, then `^{..}`/`^x` and `_{..}`/`_x` scripts.
    private static func math(_ text: String) -> String {
        var s = text
        s = s.replacingMatches(of: #"\\([A-Za-z]+)"#) { symbols[$0[1]] ?? $0[0] }
        s = s.replacingMatches(of: #"\^\{([^{}]*)\}|\^(\w)"#) { "<sup>\($0[1].isEmpty ? $0[2] : $0[1])</sup>" }
        s = s.replacingMatches(of: #"_\{([^{}]*)\}|_(\w)"#) { "<sub>\($0[1].isEmpty ? $0[2] : $0[1])</sub>" }
        return s
    }
}
