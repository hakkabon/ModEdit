import Foundation

/// Cached UTF-16 offsets for logical line starts (LF, CRLF and CR).
///
/// The index is owned by `EditorDocument`, so the status bar and the gutter
/// query the same data instead of maintaining their own copies. After an edit
/// only the changed line window is rescanned; all earlier and later line starts
/// are reused (with the later ones shifted by the edit delta).
struct LineIndex {
    private(set) var starts: [Int] = [0]

    /// Number of logical lines. Always at least one.
    var lineCount: Int { starts.count }

    init(text: String = "") { rebuild(from: text) }

    mutating func rebuild(from source: String) {
        let text = source as NSString
        let length = text.length
        starts = [0]
        guard length > 0 else { return }

        // Scan in fixed-size UTF-16 chunks. Asking `character(at:)` for every
        // position is correct but slow enough to make opening a 50 MB file take
        // seconds; one `getCharacters` call per 64k units avoids that without
        // copying the complete document into a Swift Array.
        let chunkSize = 64 * 1024
        var buffer = [unichar](repeating: 0, count: min(chunkSize, length))
        var location = 0
        var skipLeadingLF = false

        while location < length {
            let count = min(chunkSize, length - location)
            text.getCharacters(&buffer, range: NSRange(location: location, length: count))

            buffer.withUnsafeBufferPointer { characters in
                var index = 0
                if skipLeadingLF, count > 0 {
                    index = 1          // already accounted for by the preceding CR
                    skipLeadingLF = false
                }
                while index < count {
                    let character = characters[index]
                    if character == 0x0D {
                        if index + 1 < count {
                            if characters[index + 1] == 0x0A { index += 1 }
                            starts.append(location + index + 1)
                        } else if location + count < length,
                                  text.character(at: location + count) == 0x0A {
                            // CRLF split across chunks: consume the LF next time.
                            skipLeadingLF = true
                            starts.append(location + count + 1)
                        } else {
                            starts.append(location + count)
                        }
                    } else if character == 0x0A {
                        starts.append(location + index + 1)
                    }
                    index += 1
                }
            }
            location += count
        }
    }

    /// Updates the cached starts after replacing `oldRange` with text that is
    /// already present in `text` (the document *after* the edit).
    ///
    /// - Parameters:
    ///   - oldRange: The replaced range in pre-edit coordinates.
    ///   - delta: Change in UTF-16 length caused by the edit.
    ///   - text: The complete document after the edit.
    mutating func apply(editIn oldRange: NSRange, delta: Int, in text: NSString) {
        guard oldRange.location >= 0, oldRange.location <= text.length else { return }
        guard oldRange.length >= 0 else { return }
        if oldRange.length == 0 && delta == 0 { return }

        let newEnd = min(oldRange.location + oldRange.length + delta, text.length)
        var windowStart = lineStart(atOrBefore: oldRange.location)

        // A line start immediately after a lone CR may disappear when the edit
        // turns that CR into a CRLF. Start the rebuilt window one line earlier
        // so that boundary is reconsidered from stable context.
        if windowStart == oldRange.location, oldRange.location > 0,
           text.character(at: oldRange.location - 1) == 0x0D {
            windowStart = lineStart(atOrBefore: oldRange.location - 1)
        }

        // Rebuild through the end of the following line. Scanning from `newEnd`
        // only touches the remainder of one line, not the whole document.
        let windowEnd = Self.nextLineStart(atOrAfter: newEnd, in: text)
        let rebuilt = Self.lineStarts(in: text, from: windowStart, through: windowEnd)

        // Keep starts before the window, then replace everything that can have
        // changed with the rebuilt starts. Starts after the window are unchanged
        // apart from the length delta.
        let prefixEnd = firstIndex(atOrAfter: windowStart)
        let oldWindowEnd = windowEnd - delta
        let suffixStart = firstIndex(after: oldWindowEnd)

        // Replace only the changed window in place. Building a second array
        // from `starts[..<prefixEnd]` copied every line start before the edit,
        // which turns a keystroke near the end of a large file into a
        // whole-index copy.
        let rebuiltCount = rebuilt.count
        starts.replaceSubrange(prefixEnd..<suffixStart, with: rebuilt)
        let shiftedSuffixStart = prefixEnd + rebuiltCount
        for index in shiftedSuffixStart..<starts.count {
            starts[index] += delta
        }
    }

    func lineAndColumn(at location: Int) -> (line: Int, column: Int) {
        let index = max(0, firstIndex(after: location) - 1)
        return (index + 1, max(1, location - starts[index]))
    }

    /// Whether `location` is the start of a logical line.
    func isLineStart(at location: Int) -> Bool {
        let index = firstIndex(atOrAfter: location)
        return index < starts.count && starts[index] == location
    }

    // MARK: Private

    /// The last cached start at or before `location`.
    private func lineStart(atOrBefore location: Int) -> Int {
        let index = max(0, firstIndex(after: location) - 1)
        return starts[index]
    }

    /// First index whose start is >= `value`.
    private func firstIndex(atOrAfter value: Int) -> Int {
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if starts[middle] < value { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    /// First index whose start is > `value`.
    private func firstIndex(after value: Int) -> Int {
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if starts[middle] <= value { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    /// The line start after the line containing `location`, or the end of the
    /// document when that line is the last one. The result may be the document
    /// length even when it is not a line start; the inclusive rebuild below
    /// only records it when it really is one.
    private static func nextLineStart(atOrAfter location: Int, in text: NSString) -> Int {
        let length = text.length
        var index = min(max(location, 0), length)
        while index < length {
            let character = text.character(at: index)
            if character == 0x0D {
                if index + 1 < length, text.character(at: index + 1) == 0x0A {
                    return index + 2
                }
                return index + 1
            }
            if character == 0x0A { return index + 1 }
            index += 1
        }
        return length
    }

    /// Line starts in `start...end`, including both endpoints when they are
    /// genuine starts. `start` is assumed to be a line start.
    private static func lineStarts(in text: NSString, from start: Int, through end: Int) -> [Int] {
        let length = text.length
        let lower = min(max(start, 0), length)
        let upper = min(max(end, lower), length)
        var result = [lower]
        var index = lower
        while index < upper {
            let character = text.character(at: index)
            if character == 0x0D {
                if index + 1 < length, text.character(at: index + 1) == 0x0A {
                    index += 2
                } else {
                    index += 1
                }
                if index <= upper { result.append(index) }
            } else if character == 0x0A {
                index += 1
                if index <= upper { result.append(index) }
            } else {
                index += 1
            }
        }
        return result
    }
}
