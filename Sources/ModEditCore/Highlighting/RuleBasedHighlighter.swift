import AppKit

struct HighlightRule {
    let regex: NSRegularExpression
    let attributes: [NSAttributedString.Key: Any]

    init(_ pattern: String, _ attributes: [NSAttributedString.Key: Any]) throws {
        self.regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        self.attributes = attributes
    }
}

final class RuleBasedHighlighter: SyntaxHighlighter {
    let baseAttributes: [NSAttributedString.Key: Any]
    let rules: [HighlightRule]

    init(base: [NSAttributedString.Key: Any], rules: [HighlightRule]) {
        self.baseAttributes = base
        self.rules = rules
    }

    func highlight(_ storage: NSTextStorage, in requestedRange: NSRange) {
        let ns = storage.string as NSString
        let range = ns.lineRange(for: requestedRange)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: range)
        for rule in rules {
            rule.regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
                if let r = match?.range { storage.addAttributes(rule.attributes, range: r) }
            }
        }
        storage.endEditing()
    }
}
