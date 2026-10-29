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
/// To add a format: create a conforming type and include it in the
/// `FormatRegistry` you hand to the editor. The app uses
/// `FormatRegistry.standard`; tests can supply their own.
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

    /// A state machine for syntax whose meaning crosses line boundaries, or
    /// `nil` when the regex rules are enough.
    var scanner: (any StatefulScanner)? { get }

    /// A renderer for the live preview, or `nil` if the format has none.
    func makePreviewRenderer() -> (any PreviewRenderer)?
}

extension DocumentFormat {
    var scanner: (any StatefulScanner)? { nil }
}

/// Turns document source into an HTML page for the preview pane.
protocol PreviewRenderer: Sendable {
    func renderHTML(from source: String) async throws -> String
}
