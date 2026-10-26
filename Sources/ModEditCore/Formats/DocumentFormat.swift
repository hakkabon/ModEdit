import Foundation
import UniformTypeIdentifiers

/// Describes one kind of text file: how to recognise it, how to colour it and
/// how to preview it.
///
/// A format is a small, immutable, `Sendable` value. It contains **no AppKit
/// types**: syntax colouring is described semantically (`HighlightRule` ->
/// `TokenKind`) and mapped to fonts and colours by `EditorTheme`. That keeps
/// formats trivially unit-testable and makes themes (dark mode, user themes) a
/// one-place change.
///
/// To add a format: create a conforming type, then add it to
/// `FormatRegistry.standard`.
protocol DocumentFormat: Sendable {
    /// Stable identifier (used for selection and persistence).
    var id: String { get }
    /// Name shown in the UI.
    var displayName: String { get }
    /// Uniform type identifiers this format handles.
    var contentTypes: [UTType] { get }
    /// File extensions typically used by this format.
    var fileExtensions: [String] { get }

    /// Syntax-colouring rules, **lowest priority first**: when two rules match
    /// the same characters the *later* rule's attributes win. List broad,
    /// structural rules first and "opaque" ones (comments, code spans) last.
    var highlightRules: [HighlightRule] { get }

    /// Stateful syntax handling layered around the regular-expression rules.
    /// This is used for constructs whose meaning crosses line boundaries.
    var highlightingMode: HighlightingMode { get }

    /// A renderer for the live preview, or `nil` if the format has none.
    func makePreviewRenderer() -> (any PreviewRenderer)?
}

extension DocumentFormat {
    var highlightingMode: HighlightingMode { .regularExpressions }
}

/// Turns document source into an HTML page for the preview pane.
protocol PreviewRenderer: Sendable {
    func renderHTML(from source: String) async throws -> String
}
