import Foundation
import RenderedText

/// Markdown-to-HTML conversion for the live preview.
///
/// This is a thin adapter over the shared `RenderedText` projection:
/// swift-markdown parses the document once into blocks and runs, the same
/// projection that drives rendered editing, and `RenderedHTML` maps those
/// semantics to escaped HTML. The preview therefore understands setext
/// headings, nested lists, tables, strikethrough and task lists instead of the
/// small hand-written subset it used before.
///
/// ## Safety
///
/// All visible text is HTML-escaped before tags are added. Link targets are
/// restricted to `http`, `https` and `mailto`. Raw HTML from the source is
/// treated as literal text, never markup.
enum MarkdownHTML {

    /// Converts Markdown to HTML.
    ///
    /// - Parameter sourceAnchors: Adds a one-based `data-source-line`
    ///   attribute to top-level blocks (and list items). The live preview uses
    ///   these to map its scroll position to and from source lines; leaving
    ///   them off keeps the plain HTML output compact for other callers.
    /// - Parameter baseURL: The document directory, when it has one. Relative
    ///   local images become `<img>` elements so the preview's document base
    ///   URL can resolve them. Without it they remain alt text. Remote images
    ///   always remain alt text; `data:image` sources work either way.
    static func render(_ source: String,
                       sourceAnchors: Bool = false,
                       baseURL: URL? = nil) -> String {
        do {
            let document = try MarkdownRenderer().render(source)
            return RenderedHTML.render(document,
                                       sourceAnchors: sourceAnchors,
                                       allowsLocalImages: baseURL != nil)
        } catch {
            // The projection validates its own block/run invariants. A failure
            // should not hide the document, so show the escaped source instead.
            return "<pre>\(HTMLEscaping.escape(source))</pre>"
        }
    }
}
