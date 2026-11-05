import Foundation
import IncrementalParsing
import PL0Language

/// ModEdit adds presentation policy to the shared provider contract. External
/// language kits and permanent bundled formats occupy the same registry.
protocol EditorLanguageProvider: LanguageProvider {
    var documentFormat: any DocumentFormat { get }
}

struct PL0EditorLanguageProvider: EditorLanguageProvider {
    private let provider = PL0Provider()
    let documentFormat: any DocumentFormat = PL0Format()

    var descriptor: LanguageProviderDescriptor { provider.descriptor }
    func makeSession() -> any LanguageProviderSession { provider.makeSession() }
}

struct BundledFormatLanguageProvider: EditorLanguageProvider {
    let descriptor: LanguageProviderDescriptor
    let documentFormat: any DocumentFormat

    init(format: any DocumentFormat,
         distribution: LanguageProviderDistribution = .bundledPermanent) {
        self.documentFormat = format
        var capabilities: Set<LanguageProviderCapability> = [.syntaxHighlighting]
        if format.makePreviewRenderer() != nil { capabilities.insert(.preview) }
        descriptor = .init(
            id: format.id,
            displayName: format.displayName,
            fileExtensions: format.fileExtensions,
            distribution: distribution,
            capabilities: capabilities)
    }

    func makeSession() -> any LanguageProviderSession {
        do { return try BundledFormatLanguageSession(format: documentFormat) }
        catch {
            preconditionFailure(
                "Invalid bundled \(descriptor.id) highlighting rules: \(error)")
        }
    }
}

actor BundledFormatLanguageSession: LanguageProviderSession {
    private let format: any DocumentFormat
    private let tokenizer: Tokenizer

    init(format: any DocumentFormat) throws {
        self.format = format
        tokenizer = try Tokenizer(
            rules: format.highlightRules, scanner: format.scanner)
    }

    func analyze(
        _ snapshot: IncrementalParsing.SourceSnapshot,
        change: IncrementalParsing.SourceChange?
    ) async throws -> LanguageProviderAnalysis {
        if let change, change.after != snapshot {
            throw LanguageProviderError.inconsistentChange
        }
        let ns = snapshot.text as NSString
        let spans = tokenizer.tokens(
            in: ns, range: NSRange(location: 0, length: ns.length))
        return LanguageProviderAnalysis(
            languageID: format.id,
            revision: snapshot.revision,
            tokens: spans.map {
                .init(
                    range: .init(
                        location: $0.range.location, length: $0.range.length),
                    classification: String(describing: $0.kind))
            },
            operations: [.init(
                operation: "highlighting",
                evidence: .init(
                    strategy: .full,
                    measurements: [.init(
                        dimension: .init(rawValue: "highlightSpans"),
                        reused: 0,
                        rebuilt: spans.count,
                        strategy: "bundled-format-tokenizer")]))])
    }

    func previewHTML(_ snapshot: IncrementalParsing.SourceSnapshot) async throws
        -> String? {
        guard let renderer = format.makePreviewRenderer() else {
            throw LanguageProviderError.unsupportedCapability(.preview)
        }
        return try await renderer.renderHTML(from: snapshot.text)
    }
}
