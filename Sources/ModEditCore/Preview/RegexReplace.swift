import Foundation

extension String {
    /// Replaces every match of `pattern` with the result of `transform`.
    ///
    /// `transform` receives the capture groups: index 0 is the whole match,
    /// 1... are the groups, and a group that did not participate is `""`.
    /// Needed because `replacingOccurrences(options: .regularExpression)` only
    /// supports static templates, not computed replacements.
    ///
    /// Patterns are compile-time constants in this codebase, so an invalid one
    /// is a programmer error: it trips `assertionFailure` in debug builds and
    /// returns the string unchanged in release builds.
    func replacingMatches(of pattern: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            assertionFailure("Invalid regular expression: \(pattern)")
            return self
        }
        let ns = self as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += transform(groups)
            cursor = NSMaxRange(match.range)
        }
        result += ns.substring(from: cursor)
        return result
    }
}
