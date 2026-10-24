import Foundation

/// Escaping for text that is inserted into HTML.
enum HTMLEscaping {
    /// Escapes `& < > " '` so `text` is inert in element content *and* in
    /// quoted attribute values.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&#39;"
            default:   out.append(character)
            }
        }
        return out
    }
}

/// The HTML page that wraps rendered preview bodies.
enum PreviewPage {
    /// Wraps `body` in a complete document with shared styling.
    ///
    /// The Content-Security-Policy forbids scripts, remote loads and frames, so
    /// even if an escaping bug let markup through it could not execute code.
    /// `color-scheme` makes the preview follow light/dark mode.
    static func wrap(body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        <style>
        :root { color-scheme: light dark; }
        body { font-family: -apple-system, sans-serif; line-height: 1.5; padding: 20px; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; }
        code, pre { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
        code { background: rgba(127,127,127,0.15); padding: 1px 5px; border-radius: 3px; }
        pre { background: rgba(127,127,127,0.12); padding: 12px; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { margin-left: 0; padding-left: 12px; border-left: 3px solid rgba(127,127,127,0.5); color: gray; }
        .math { font-family: "STIX Two Math", "Times New Roman", serif; font-style: italic; }
        .math.display { display: block; text-align: center; margin: 1em 0; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}
