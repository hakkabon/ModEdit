import Foundation

/// Runs a renderer away from the main actor.
///
/// Rendering is pure (no AppKit or WebKit types), but on a multi-megabyte
/// document it can take long enough to drop frames while typing. The preview
/// snapshots its source on the main actor, hands the immutable `String` to a
/// detached task, and only touches `WKWebView` again when the HTML is ready.
///
/// A detached task does not inherit actor isolation, and cancellation is
/// forwarded so a superseded render can stop when the renderer observes it.
enum PreviewRendering {
    static func renderHTML(from source: String,
                           with renderer: any PreviewRenderer) async throws -> String {
        let task = Task.detached(priority: .userInitiated) {
            try await renderer.renderHTML(from: source)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

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
