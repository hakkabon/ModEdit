import Foundation

final class MarkdownPreviewRenderer: PreviewRenderer {
    func renderHTML(from source: String) async throws -> String {
        let escaped = source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = escaped
            .replacingOccurrences(of: "### (.*)", with: "<h3>$1</h3>", options: .regularExpression)
            .replacingOccurrences(of: "## (.*)", with: "<h2>$1</h2>", options: .regularExpression)
            .replacingOccurrences(of: "# (.*)", with: "<h1>$1</h1>", options: .regularExpression)
            .replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
            .replacingOccurrences(of: "\\*(.*?)\\*", with: "<em>$1</em>", options: .regularExpression)
            .replacingOccurrences(of: "`(.*?)`", with: "<code>$1</code>", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: "<br>")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <style>
        body { font-family: -apple-system, sans-serif; padding: 20px; color: #333; }
        h1, h2, h3 { color: #1a73e8; }
        code { background: #f5f5f5; padding: 2px 6px; border-radius: 3px; }
        </style>
        </head>
        <body>\(html)</body>
        </html>
        """
    }
}

final class LaTeXPreviewRenderer: PreviewRenderer {
    func renderHTML(from source: String) async throws -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <style>body { font-family: monospace; padding: 20px; white-space: pre-wrap; }</style>
        </head>
        <body>\(source)</body>
        </html>
        """
    }
}

final class HTMLPreviewRenderer: PreviewRenderer {
    func renderHTML(from source: String) async throws -> String {
        return source
    }
}
