import Foundation

/// Markdown preview: converts with `MarkdownHTML` and wraps in the shared page.
struct MarkdownPreviewRenderer: PreviewRenderer {
    func renderHTML(from source: String) async throws -> String {
        PreviewPage.wrap(body: MarkdownHTML.render(source))
    }
}

/// LaTeX preview: a lightweight rendering of common constructs (see `LaTeXHTML`).
struct LaTeXPreviewRenderer: PreviewRenderer {
    func renderHTML(from source: String) async throws -> String {
        PreviewPage.wrap(body: LaTeXHTML.render(source))
    }
}

/// HTML preview: shows the user's own page as written.
///
/// The preview web view runs with JavaScript disabled and blocks navigation
/// (see `PreviewPane`), so scripts in the document do not execute. Relative
/// resources (images, stylesheets) do not resolve because `DocumentGroup` does
/// not expose the file URL; that needs an `NSDocument`-based app.
struct HTMLPreviewRenderer: PreviewRenderer {
    func renderHTML(from source: String) async throws -> String { source }
}
