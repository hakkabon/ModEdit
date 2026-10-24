import Foundation
import UniformTypeIdentifiers

/// The set of known formats.
///
/// This is an **immutable value**, not a mutable singleton: there is no
/// registration step that can be forgotten or raced, and tests can build their
/// own registry.
struct FormatRegistry: Sendable {
    /// Specific formats, in matching priority order.
    let formats: [any DocumentFormat]
    /// Used when nothing more specific matches.
    let fallback: any DocumentFormat

    static let standard = FormatRegistry(
        formats: [MarkdownFormat(), LaTeXFormat(), HTMLFormat()],
        fallback: PlainTextFormat())

    /// Every format, fallback last. Used to populate pickers.
    var allFormats: [any DocumentFormat] { formats + [fallback] }

    /// Content types the app can open. Source types without a dedicated format
    /// (XML, JSON, YAML) are opened as plain text.
    var readableContentTypes: [UTType] {
        allFormats.flatMap { $0.contentTypes } + [.xml, .json, .yaml]
    }

    /// Picks the format for `type`.
    ///
    /// Matching order matters. Markdown and LaTeX both *conform to* plain text,
    /// so a naive "first format that the type conforms to" lookup, with plain
    /// text registered first, would hand every Markdown file to the plain-text
    /// format. We therefore try an exact match, then conformance to the
    /// *specific* formats, and only then the fallback.
    func format(for type: UTType) -> any DocumentFormat {
        if let exact = allFormats.first(where: { $0.contentTypes.contains(type) }) {
            return exact
        }
        return formats.first { format in
            format.contentTypes.contains { type.conforms(to: $0) }
        } ?? fallback
    }

    /// Looks a format up by `DocumentFormat.id`.
    func format(withID id: String) -> (any DocumentFormat)? {
        allFormats.first { $0.id == id }
    }
}
