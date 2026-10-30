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
    /// The policy shared by generated and user-supplied HTML.
    ///
    /// It forbids scripts, remote loads, frames and form submissions. Inline
    /// styles are allowed so documents still look like themselves; `data:`
    /// images/fonts keep self-contained files working. `base-uri` prevents a
    /// `<base>` tag from redirecting links elsewhere.
    static let contentSecurityPolicy = """
        default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; \
        img-src data:; font-src data:; media-src data:; connect-src 'none'; \
        frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'
        """

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
        \(policyMeta)
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

    /// Injects the preview policy into a user-supplied HTML document.
    ///
    /// HTML files are shown as written, so they cannot use `wrap(body:)`
    /// without breaking full documents. Injecting the policy as early as
    /// possible keeps subsequent subresource loads and inline scripts inert.
    static func hardenHTMLDocument(_ source: String) -> String {
        let meta = policyMeta + colorSchemeStyle

        if let head = source.range(of: #"(?i)<head\b[^>]*>"#,
                                   options: .regularExpression) {
            var result = source
            result.insert(contentsOf: meta, at: head.upperBound)
            return result
        }

        if let html = source.range(of: #"(?i)<html\b[^>]*>"#,
                                   options: .regularExpression) {
            var result = source
            result.insert(contentsOf: "<head>\(meta)</head>", at: html.upperBound)
            return result
        }

        if let doctype = source.range(of: #"(?i)<!doctype\b[^>]*>"#,
                                      options: .regularExpression) {
            var result = source
            result.insert(contentsOf: meta, at: doctype.upperBound)
            return result
        }

        return meta + source
    }

    private static let policyMeta =
        #"<meta http-equiv="Content-Security-Policy" content="\#(contentSecurityPolicy)">"#

    /// User HTML documents are shown as written, but native controls and the
    /// default canvas should still follow the system appearance.
    private static let colorSchemeStyle = "<style>:root { color-scheme: light dark; }</style>"
}
