import Foundation
import IncrementalParsing
import LanguageTooling

struct HTMLEmbeddedRegionResolver: EmbeddedLanguageRegionResolver {
    func regions(in snapshot: SourceSnapshot) -> [EmbeddedLanguageRegion] {
        let source = snapshot.text as NSString
        var regions: [EmbeddedLanguageRegion] = []
        regions += matches(
            #"<style\b[^>]*>(.*?)</style\s*>"#,
            languageID: "css", in: source)
        regions += matches(
            #"<script\b(?=[^>]*\btype\s*=\s*["']application/(?:ld\+)?json["'])[^>]*>(.*?)</script\s*>"#,
            languageID: "json", in: source)
        return regions.sorted {
            ($0.range.location, $0.id) < ($1.range.location, $1.id)
        }
    }

    private func matches(
        _ pattern: String, languageID: String, in source: NSString
    ) -> [EmbeddedLanguageRegion] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }
        return expression.matches(
            in: source as String,
            range: NSRange(location: 0, length: source.length)
        ).enumerated().compactMap { ordinal, match in
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { return nil }
            return .init(
                id: "html.\(languageID).\(ordinal)",
                languageID: languageID,
                range: .init(location: range.location, length: range.length))
        }
    }
}

struct MarkdownEmbeddedRegionResolver: EmbeddedLanguageRegionResolver {
    private static let aliases: [String: String] = [
        "json": "json",
        "css": "css",
        "dot": "dot", "graphviz": "dot",
        "bnf": "grammar", "ebnf": "grammar", "wsn": "grammar",
        "grammar": "grammar",
    ]

    func regions(in snapshot: SourceSnapshot) -> [EmbeddedLanguageRegion] {
        let source = snapshot.text as NSString
        guard let opening = try? NSRegularExpression(
            pattern: #"(?m)^[ \t]*(`{3,}|~{3,})[ \t]*([A-Za-z0-9_+-]+)[^\r\n]*(?:\r\n|\n|\r)"#)
        else { return [] }
        var searchOffset = 0
        var ordinals: [String: Int] = [:]
        var result: [EmbeddedLanguageRegion] = []
        while searchOffset < source.length,
              let match = opening.firstMatch(
                in: source as String,
                range: NSRange(
                    location: searchOffset, length: source.length - searchOffset)) {
            let fence = source.substring(with: match.range(at: 1))
            let label = source.substring(with: match.range(at: 2)).lowercased()
            let contentStart = NSMaxRange(match.range)
            guard let languageID = Self.aliases[label],
                  let closing = closingFence(
                    fence, in: source, after: contentStart) else {
                searchOffset = contentStart
                continue
            }
            let ordinal = ordinals[languageID, default: 0]
            ordinals[languageID] = ordinal + 1
            result.append(.init(
                id: "markdown.\(languageID).\(ordinal)",
                languageID: languageID,
                range: .init(
                    location: contentStart,
                    length: closing.location - contentStart)))
            searchOffset = NSMaxRange(closing)
        }
        return result
    }

    private func closingFence(
        _ fence: String, in source: NSString, after offset: Int
    ) -> NSRange? {
        let character = String(fence.prefix(1))
        let pattern = "(?m)^[ \\t]*"
            + NSRegularExpression.escapedPattern(for: character)
            + "{\(fence.count),}[ \\t]*(?:\\r?$)"
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        return expression.firstMatch(
            in: source as String,
            range: NSRange(location: offset, length: source.length - offset))?.range
    }
}
