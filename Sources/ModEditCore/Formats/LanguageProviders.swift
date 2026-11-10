import CSSLanguage
import DOTLanguage
import Foundation
import GrammarLanguage
import IncrementalParsing
import JSONLanguage
import LanguageTooling
import PL0Language

/// ModEdit adds presentation policy to the shared provider contract. External
/// language kits and permanent bundled formats occupy the same registry.
protocol EditorLanguageProvider: LanguageToolingProvider {
    var documentFormat: any DocumentFormat { get }
}

struct PL0EditorLanguageProvider: EditorLanguageProvider {
    private let provider = PL0Provider()
    let documentFormat: any DocumentFormat = PL0Format()

    var descriptor: LanguageProviderDescriptor { provider.descriptor }
    func makeToolingSession() -> any LanguageToolingSession {
        provider.makeToolingSession()
    }
}

struct JSONEditorLanguageProvider: EditorLanguageProvider {
    private let provider = JSONProvider()
    let documentFormat: any DocumentFormat = JSONFormat()

    var descriptor: LanguageProviderDescriptor { provider.descriptor }
    func makeToolingSession() -> any LanguageToolingSession {
        provider.makeToolingSession()
    }
}

struct GrammarEditorLanguageProvider: EditorLanguageProvider {
    private let provider = GrammarProvider()
    let documentFormat: any DocumentFormat = GrammarFormat()

    var descriptor: LanguageProviderDescriptor { provider.descriptor }
    func makeToolingSession() -> any LanguageToolingSession {
        provider.makeToolingSession()
    }
}

struct DOTEditorLanguageProvider: EditorLanguageProvider {
    private let provider = DOTProvider()
    let documentFormat: any DocumentFormat = DOTFormat()

    var descriptor: LanguageProviderDescriptor { provider.descriptor }
    func makeToolingSession() -> any LanguageToolingSession {
        provider.makeToolingSession()
    }
}

struct CSSEditorLanguageProvider: EditorLanguageProvider {
    private let provider = CSSProvider()
    let documentFormat: any DocumentFormat = CSSFormat()

    var descriptor: LanguageProviderDescriptor { provider.descriptor }
    func makeToolingSession() -> any LanguageToolingSession {
        provider.makeToolingSession()
    }
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

    func makeToolingSession() -> any LanguageToolingSession {
        do { return try BundledFormatLanguageSession(format: documentFormat) }
        catch {
            preconditionFailure(
                "Invalid bundled \(descriptor.id) highlighting rules: \(error)")
        }
    }
}

actor BundledFormatLanguageSession: LanguageToolingSession {
    private let format: any DocumentFormat
    private let tokenizer: Tokenizer
    private var currentText: String?
    private var currentRevision: SourceRevision?
    private var currentSpans: [Token] = []

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
        currentText = snapshot.text
        currentRevision = snapshot.revision
        currentSpans = spans
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

    func semanticTokens() async throws -> ToolingSemanticTokensResult {
        guard let currentText, let currentRevision else {
            throw LanguageToolingError.documentNotAnalyzed
        }
        let tokens = semanticTokens(
            from: effectiveSpans(currentSpans), in: currentText)
        return SemanticTokenEncoder.encode(
            tokens,
            resultID: "\(format.id):\(currentRevision.rawValue)")
    }

    private func semanticTokens(
        from spans: [Token],
        in text: String
    ) -> [ToolingSemanticToken] {
        let source = text as NSString
        let lineMap = SourceLineMap(text)
        return spans.flatMap { span in
            var result: [ToolingSemanticToken] = []
            var lower = span.range.location
            let upper = NSMaxRange(span.range)
            while lower < upper {
                var lineEnd = lower
                while lineEnd < upper {
                    let unit = source.character(at: lineEnd)
                    if unit == 10 || unit == 13 { break }
                    lineEnd += 1
                }
                if lineEnd > lower {
                    result.append(.init(
                        range: lineMap.toolingRange(.init(
                            location: lower, length: lineEnd - lower)),
                        type: semanticType(span.kind)))
                }
                guard lineEnd < upper else { break }
                lower = lineEnd + 1
                if source.character(at: lineEnd) == 13,
                   lower < upper,
                   source.character(at: lower) == 10 {
                    lower += 1
                }
            }
            return result
        }
    }

    private func semanticType(_ kind: TokenKind) -> ToolingSemanticTokenType {
        switch kind {
        case .comment: .comment
        case .string, .code: .string
        case .keyword: .keyword
        case .number: .number
        case .operator, .listMarker: .operatorToken
        case .attributeName: .field
        case .argument, .optionalArgument: .parameter
        case .tag, .command, .heading: .type
        case .math, .strong, .link, .quote: .variable
        }
    }

    /// Highlight rules are priority ordered and may overlap. Semantic-token
    /// protocols require a disjoint stream, so split at every boundary and
    /// retain the last (highest-priority) covering span.
    private func effectiveSpans(_ spans: [Token]) -> [Token] {
        let boundaries = Set(spans.flatMap {
            [$0.range.location, NSMaxRange($0.range)]
        }).sorted()
        var result: [Token] = []
        for (lower, upper) in zip(boundaries, boundaries.dropFirst())
            where lower < upper {
            guard let winner = spans.last(where: {
                $0.range.location <= lower && NSMaxRange($0.range) >= upper
            }) else { continue }
            if let previous = result.last,
               previous.kind == winner.kind,
               NSMaxRange(previous.range) == lower {
                result[result.count - 1] = Token(
                    range: NSRange(
                        location: previous.range.location,
                        length: upper - previous.range.location),
                    kind: winner.kind)
            } else {
                result.append(Token(
                    range: NSRange(location: lower, length: upper - lower),
                    kind: winner.kind))
            }
        }
        return result
    }
}
