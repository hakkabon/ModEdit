import Foundation
import Markdown

/// Converts swift-markdown's UTF-8 line/column locations into UTF-16 offsets.
///
/// `SourceLocation.column` counts UTF-8 bytes, while the rendered model uses
/// UTF-16 offsets to match `NSTextStorage` and `NSString`. The index is built
/// once per parse and reused for every node in the tree.
struct SourceOffsetIndex {
    private let source: NSString
    private let lineStarts: [Int]

    init(_ source: String) {
        let text = source as NSString
        self.source = text

        var starts = [0]
        var index = 0
        let length = text.length
        while index < length {
            let character = text.character(at: index)
            if character == 0x0D {
                if index + 1 < length, text.character(at: index + 1) == 0x0A {
                    index += 2
                } else {
                    index += 1
                }
                starts.append(index)
            } else if character == 0x0A {
                index += 1
                starts.append(index)
            } else {
                index += 1
            }
        }
        self.lineStarts = starts
    }

    var length: Int { source.length }
    var lineCount: Int { lineStarts.count }

    /// Converts a source location to a UTF-16 offset.
    ///
    /// If the byte column falls inside a multi-byte character, the offset moves
    /// back to that character's start, matching the parser's token boundaries.
    func offset(for location: SourceLocation) -> Int? {
        let lineIndex = location.line - 1
        guard lineIndex >= 0, lineIndex < lineStarts.count else { return nil }
        let lineStart = lineStarts[lineIndex]
        let lineEnd = lineIndex + 1 < lineStarts.count
            ? lineStarts[lineIndex + 1]
            : source.length
        let targetBytes = max(0, location.column - 1)

        var bytes = 0
        var utf16 = 0
        var index = lineStart
        while index < lineEnd {
            let unit = source.character(at: index)
            if unit == 0x0A || unit == 0x0D { break }

            let characterLength: Int
            if unit >= 0xD800, unit <= 0xDBFF,
               index + 1 < lineEnd {
                let next = source.character(at: index + 1)
                characterLength = (next >= 0xDC00 && next <= 0xDFFF) ? 2 : 1
            } else {
                characterLength = 1
            }

            let character = source.substring(
                with: NSRange(location: index, length: characterLength))
            let byteLength = character.utf8.count
            if bytes + byteLength > targetBytes { break }
            bytes += byteLength
            utf16 += characterLength
            index += characterLength
            if bytes == targetBytes { break }
        }
        return lineStart + utf16
    }

    /// Converts a parser range to a clamped UTF-16 range.
    func range(for range: SourceRange?) -> Range<Int>? {
        guard let range,
              let lower = offset(for: range.lowerBound),
              let upper = offset(for: range.upperBound),
              lower <= upper,
              upper <= source.length else { return nil }
        return lower..<upper
    }

    /// The length of the newline at `index`, or zero when there is none.
    func newlineLength(at index: Int) -> Int {
        guard index >= 0, index < source.length else { return 0 }
        if source.character(at: index) == 0x0D {
            if index + 1 < source.length,
               source.character(at: index + 1) == 0x0A {
                return 2
            }
            return 1
        }
        if source.character(at: index) == 0x0A { return 1 }
        return 0
    }

    /// The end of the line containing `index`, including its newline.
    func lineEnd(after index: Int, limitedTo limit: Int) -> Int {
        var cursor = max(0, min(index, limit))
        while cursor < limit {
            let length = newlineLength(at: cursor)
            if length > 0 { return cursor + length }
            cursor += 1
        }
        return limit
    }

    /// The start of the line containing `index`.
    func lineStart(containing index: Int) -> Int {
        guard !lineStarts.isEmpty else { return 0 }
        var lower = 0
        var upper = lineStarts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] <= index {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lineStarts[max(0, lower - 1)]
    }

    /// All line ranges intersecting `range`, including trailing newlines.
    func lineRanges(in range: Range<Int>) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var cursor = max(0, range.lowerBound)
        let limit = min(range.upperBound, source.length)
        while cursor < limit {
            let end = lineEnd(after: cursor, limitedTo: limit)
            result.append(cursor..<end)
            cursor = end
        }
        return result
    }

    /// The first newline in `range`, if any.
    func firstNewline(in range: Range<Int>) -> (index: Int, length: Int)? {
        var cursor = max(0, range.lowerBound)
        let limit = min(range.upperBound, source.length)
        while cursor < limit {
            let length = newlineLength(at: cursor)
            if length > 0 { return (cursor, length) }
            cursor += 1
        }
        return nil
    }

    /// Whether the newline at `index` is a hard break.
    ///
    /// CommonMark hard breaks are two or more trailing spaces or a backslash
    /// immediately before the newline.
    func isHardBreak(newlineAt index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = source.character(at: index - 1)
        if previous == 0x5C { return true }
        guard previous == 0x20 else { return false }
        return index > 1 && source.character(at: index - 2) == 0x20
    }

    func text(in range: Range<Int>) -> String {
        let lower = max(0, min(range.lowerBound, source.length))
        let upper = max(lower, min(range.upperBound, source.length))
        return source.substring(with: NSRange(location: lower, length: upper - lower))
    }
}
