import Foundation
import LanguageTooling
import ModEditBundledLanguages
import UniformTypeIdentifiers

/// The set of known formats.
///
/// This is an **immutable value**, not a mutable singleton: there is no
/// registration step that can be forgotten or raced, and tests can build their
/// own registry.
struct FormatRegistry: Sendable {
    /// Specific providers, in matching priority order.
    let providers: [any EditorLanguageProvider]
    /// Used when nothing more specific matches.
    let fallbackProvider: any EditorLanguageProvider

    static let standard: FormatRegistry = {
        let json = JSONEditorLanguageProvider()
        let grammar = GrammarEditorLanguageProvider()
        let dot = DOTEditorLanguageProvider()
        let css = CSSEditorLanguageProvider()
        let embedded: [any LanguageToolingProvider] = [
            json, grammar, dot, css,
        ]
        let registry = FormatRegistry(
            providers: [
                PL0EditorLanguageProvider(),
                json,
                grammar,
                dot,
                css,
                EmbeddedEditorLanguageProvider(
                    host: BundledFormatLanguageProvider(
                        format: MarkdownFormat()),
                    embedded: embedded,
                    resolver: MarkdownEmbeddedRegionResolver()),
                BundledFormatLanguageProvider(format: LaTeXFormat()),
                EmbeddedEditorLanguageProvider(
                    host: BundledFormatLanguageProvider(format: HTMLFormat()),
                    embedded: [css, json],
                    resolver: HTMLEmbeddedRegionResolver()),
            ],
            fallbackProvider: BundledFormatLanguageProvider(
                format: PlainTextFormat()))
        let permanentIDs = Set(registry.providers.compactMap {
            $0.descriptor.distribution == .bundledPermanent
                ? $0.descriptor.id : nil
        })
        precondition(
            permanentIDs == ModEditBundledLanguageCatalog.activeProviderIDs,
            "ModEdit's permanent providers must match its distribution catalog")
        return registry
    }()

    init(providers: [any EditorLanguageProvider],
         fallbackProvider: any EditorLanguageProvider) {
        precondition(Set((providers + [fallbackProvider]).map {
            $0.descriptor.id
        }).count == providers.count + 1,
        "language provider IDs must be unique")
        self.providers = providers
        self.fallbackProvider = fallbackProvider
    }

    /// Compatibility initializer for host-defined presentation-only formats.
    init(formats: [any DocumentFormat], fallback: any DocumentFormat) {
        self.init(
            providers: formats.map {
                BundledFormatLanguageProvider(
                    format: $0, distribution: .hostDefined)
            },
            fallbackProvider: BundledFormatLanguageProvider(
                format: fallback, distribution: .hostDefined))
    }

    var formats: [any DocumentFormat] { providers.map(\.documentFormat) }
    var fallback: any DocumentFormat { fallbackProvider.documentFormat }

    var allProviders: [any EditorLanguageProvider] {
        providers + [fallbackProvider]
    }

    /// Every format, fallback last. Used to populate pickers.
    var allFormats: [any DocumentFormat] {
        allProviders.map(\.documentFormat)
    }

    /// Content types the app can open. Source types without a dedicated format
    /// (XML and YAML) are opened as plain text.
    var readableContentTypes: [UTType] {
        allFormats.flatMap { $0.contentTypes } + [.xml, .yaml]
    }

    /// Picks the format for `type`.
    ///
    /// Matching order matters. Markdown and LaTeX both *conform to* plain text,
    /// so a naive "first format that the type conforms to" lookup, with plain
    /// text registered first, would hand every Markdown file to the plain-text
    /// format. We therefore try an exact match, then conformance to the
    /// *specific* formats, and only then the fallback.
    func format(for type: UTType) -> any DocumentFormat {
        provider(for: type).documentFormat
    }

    /// Looks a format up by `DocumentFormat.id`.
    func format(withID id: String) -> (any DocumentFormat)? {
        provider(withID: id)?.documentFormat
    }

    func provider(for type: UTType) -> any EditorLanguageProvider {
        if let exact = allProviders.first(where: {
            $0.documentFormat.contentTypes.contains(type)
        }) {
            return exact
        }
        return providers.first { provider in
            provider.documentFormat.contentTypes.contains {
                type.conforms(to: $0)
            }
        } ?? fallbackProvider
    }

    func provider(withID id: String) -> (any EditorLanguageProvider)? {
        allProviders.first { $0.descriptor.id == id }
    }
}
