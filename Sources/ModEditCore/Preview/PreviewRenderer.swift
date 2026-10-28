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

/// HTML preview: shows the user's own page as written, inside the same
/// hardening shell as the generated previews.
///
/// The preview web view disables JavaScript, uses a non-persistent data store
/// and blocks non-initial navigation (see `PreviewPane`). The injected
/// Content-Security-Policy additionally blocks scripts, frames and remote
/// subresources. Relative resources (images, stylesheets) do not resolve yet
/// because the page has no file `baseURL`; the document shell now exposes the
/// URL, so that can be wired up next.
struct HTMLPreviewRenderer: PreviewRenderer {
    func renderHTML(from source: String) async throws -> String {
        PreviewPage.hardenHTMLDocument(source)
    }
}
