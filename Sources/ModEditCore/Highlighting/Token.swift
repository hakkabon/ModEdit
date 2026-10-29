import Darwin
import Foundation

/// What a piece of text *is*, independent of how it is drawn.
///
/// Formats classify text into kinds; `EditorTheme` decides fonts and colours.
/// Keeping the two apart makes rules testable without AppKit and makes
/// re-theming trivial.
enum TokenKind: Sendable, Hashable, CaseIterable {
    case comment
    case tag
    case attributeName
    case string
    case command
    case math
    case argument
    case optionalArgument
    case heading
    case strong
    case code
    case link
    case quote
    case listMarker
}

/// Selects the state machine used around a format's regex rules.
enum HighlightingMode: Sendable {
    case regularExpressions
    case markdown
    case html
}

/// A regular expression that classifies the text it matches.
///
/// Holds only a pattern string so it is `Sendable`; compilation happens in
/// `Tokenizer`, which reports invalid patterns by throwing (and the test suite
/// compiles every shipped rule, so a typo cannot silently disable highlighting).
struct HighlightRule: Sendable {
    let pattern: String
    let kind: TokenKind

    init(_ pattern: String, _ kind: TokenKind) {
        self.pattern = pattern
        self.kind = kind
    }
}

/// A classified range. Ranges are UTF-16 offsets (`NSRange`).
struct Token: Equatable, Sendable {
    let range: NSRange
    let kind: TokenKind
}

/// Finds tokens by running a format's rules over (part of) a string.
///
/// Tokens are returned **in rule order**. Applying them in that order, later
/// rules overwrite earlier ones, which is the priority scheme documented on
/// `DocumentFormat.highlightRules`.
///
/// Local syntax uses ordered regular expressions. Formats can additionally
/// select a small state machine for constructs that cross line boundaries,
/// currently Markdown fences and HTML tags/comments.
struct Tokenizer {
    private struct CompiledRule {
        let regex: NSRegularExpression
        let kind: TokenKind
    }

    /// Multiline state at a line boundary.
    ///
    /// A full-document pass carries one `State` across line-aligned chunks, so
    /// the Markdown/HTML scanners visit every character once instead of
    /// re-scanning the prefix for each chunk. A local dirty-line pass instead
    /// starts from the nearest entry in `Checkpoints`, so it only replays the
    /// text between that snapshot and the dirty lines.
    struct State: Equatable, Sendable {
        /// UTF-16 offset up to which the state machine has consumed text.
        fileprivate(set) var scanLocation = 0
        fileprivate var markdownFenceStart: Int?
        fileprivate var htmlCommentStart: Int?
        fileprivate var htmlTagStart: Int?
        fileprivate var htmlTagQuote: unichar?

        init() {}
    }

    /// A bounded cache of scanner snapshots at line boundaries.
    ///
    /// A snapshot is the complete `State` after consuming `[0, offset)`.
    /// Because the Markdown and HTML scanners are purely forward state
    /// machines, a local pass may resume from any snapshot at or before the
    /// dirty lines and produce exactly the same tokens as a scan from offset 0.
    ///
    /// Snapshots become invalid when characters change: an edit at `location`
    /// can alter the interpretation of every offset at or after it. Callers
    /// must call `invalidate(from:)` for each edit; `StorageHighlighter` does
    /// that from the text-storage delegate.
    struct Checkpoints: Sendable {
        struct Entry: Sendable, Equatable {
            let offset: Int
            let state: State
        }

        /// Minimum UTF-16 distance between snapshots. This keeps the cache
        /// proportional to document size; in normal editing the nearest
        /// snapshot before a dirty line is one full-pass chunk away.
        static let spacing = 32 * 1_024

        private(set) var entries: [Entry] = []

        var count: Int { entries.count }

        var offsets: [Int] { entries.map(\.offset) }

        /// The snapshot with the greatest offset at or before `location`, or
        /// `nil` when the caller has to start at the document start.
        func state(atOrBefore location: Int) -> State? {
            // Upper-bound search: first entry whose offset is greater than
            // `location`; the entry before it is the one to reuse.
            var low = 0
            var high = entries.count
            while low < high {
                let middle = low + (high - low) / 2
                if entries[middle].offset <= location {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            guard low > 0 else { return nil }
            return entries[low - 1].state
        }

        /// Records a snapshot at a line-aligned `offset`.
        ///
        /// An existing snapshot at the same offset is replaced. Otherwise the
        /// snapshot is skipped when it is closer than `spacing` to either
        /// neighbour, which keeps the number of snapshots proportional to
        /// document size rather than to the number of edits.
        mutating func record(_ state: State, at offset: Int) {
            guard offset >= 0 else { return }

            let index = insertionIndex(for: offset)
            if index < entries.count, entries[index].offset == offset {
                entries[index] = Entry(offset: offset, state: state)
                return
            }
            if index > 0, offset - entries[index - 1].offset < Self.spacing {
                return
            }
            if index < entries.count, entries[index].offset - offset < Self.spacing {
                return
            }
            entries.insert(Entry(offset: offset, state: state), at: index)
        }

        /// Drops every snapshot at or after `location`. Text after an edit is
        /// either different or shifted, so those states can no longer be
        /// trusted.
        mutating func invalidate(from location: Int) {
            let index = insertionIndex(for: location)
            if index < entries.count {
                entries.removeSubrange(index...)
            }
        }

        mutating func removeAll() {
            entries.removeAll(keepingCapacity: true)
        }

        /// First index whose entry offset is at least `offset`.
        private func insertionIndex(for offset: Int) -> Int {
            var low = 0
            var high = entries.count
            while low < high {
                let middle = low + (high - low) / 2
                if entries[middle].offset < offset {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low
        }
    }

    private let rules: [CompiledRule]
    private let mode: HighlightingMode

    /// - Throws: if any rule's pattern is not a valid regular expression.
    init(rules: [HighlightRule], mode: HighlightingMode = .regularExpressions) throws {
        self.mode = mode
        self.rules = try rules.map {
            CompiledRule(
                regex: try NSRegularExpression(pattern: $0.pattern, options: [.anchorsMatchLines]),
                kind: $0.kind)
        }
    }

    /// Tokens whose matches lie within `range` of `text`.
    ///
    /// `range` should start and end on line boundaries so `^` and `$` behave.
    func tokens(in text: String, range: NSRange) -> [Token] {
        tokens(in: text as NSString, range: range)
    }

    /// NSString overload used by the editor. `NSTextStorage.mutableString` can
    /// be passed directly, so a highlight pass never copies the whole document.
    func tokens(in text: NSString, range: NSRange) -> [Token] {
        var state = State()
        return tokens(in: text, range: range, state: &state)
    }

    /// Tokens for one line-aligned chunk of a full-document pass.
    ///
    /// `state` must describe the text immediately before `range` and is
    /// advanced to its end. Pass a fresh `State()` for the first chunk, or for
    /// a local pass that recovers state from the document start.
    func tokens(in text: NSString, range: NSRange, state: inout State) -> [Token] {
        let documentRange = NSRange(location: 0, length: text.length)
        let requested = NSIntersectionRange(range, documentRange)
        guard requested.location != NSNotFound else { return [] }

        var scanner = ChunkScanner()
        let htmlTokens = mode == .html
            ? scanHTML(in: text, clippedTo: requested, state: &state, scanner: &scanner)
            : (tags: [], comments: [])
        var result: [Token] = htmlTokens.tags

        // Regexes run over only the requested lines. The substring is the only
        // copy a local pass makes, and it is proportional to the dirty range,
        // not to the document.
        if requested.length > 0 {
            let local = text.substring(with: requested)
            let localRange = NSRange(location: 0, length: (local as NSString).length)
            for rule in rules {
                rule.regex.enumerateMatches(in: local, options: [], range: localRange) { match, _, _ in
                    guard let match, match.range.length > 0 else { return }
                    let range = NSRange(location: match.range.location + requested.location,
                                        length: match.range.length)
                    if mode == .html,
                       !htmlTokens.tags.contains(where: { NSLocationInRange(range.location, $0.range) }) {
                        return
                    }
                    result.append(Token(range: range, kind: rule.kind))
                }
            }
        }

        if mode == .markdown {
            // Fenced blocks are opaque, so append them after inline rules.
            result.append(contentsOf: markdownFenceTokens(in: text, clippedTo: requested,
                                                          state: &state, scanner: &scanner))
        } else if mode == .html {
            // Comments are opaque and must override tag/attribute/string tokens.
            result.append(contentsOf: htmlTokens.comments)
        }

        // The state machine has consumed every character in `requested`. The
        // full-document pass splits on line boundaries, so the next chunk
        // starts exactly here.
        state.scanLocation = NSMaxRange(requested)
        return result
    }

    /// Tokens for a local dirty-line pass that can reuse cached state.
    ///
    /// `state` normally comes from `checkpoints.state(atOrBefore:)`, or is a
    /// fresh `State()` when no snapshot exists. The resulting state is recorded
    /// so a later pass after these lines does not have to replay the prefix.
    func tokens(in text: NSString,
                range: NSRange,
                state: inout State,
                checkpoints: inout Checkpoints) -> [Token] {
        let tokens = tokens(in: text, range: range, state: &state)
        checkpoints.record(state, at: state.scanLocation)
        return tokens
    }

    private func clippedToken(_ range: NSRange, kind: TokenKind, to requested: NSRange) -> Token? {
        let clipped = NSIntersectionRange(range, requested)
        guard clipped.location != NSNotFound, clipped.length > 0 else { return nil }
        return Token(range: clipped, kind: kind)
    }

    /// Scans from the state's position so a requested range starting inside a
    /// fence still has the correct state. Tokens are clipped to the requested
    /// lines.
    ///
    /// Candidate delimiters are found with a chunked `memchr` scan. Scanning
    /// resumes where the previous chunk stopped (`state.scanLocation`), so a
    /// full pass does not re-read the document prefix for every chunk.
    private func markdownFenceTokens(in text: NSString,
                                     clippedTo requested: NSRange,
                                     state: inout State,
                                     scanner: inout ChunkScanner) -> [Token] {
        var result: [Token] = []
        let scanLimit = NSMaxRange(requested)
        let scanStart = max(state.scanLocation, 0)
        var searchLocation = scanStart

        while searchLocation < scanLimit {
            guard let found = scanner.firstIndex(of: 0x60, in: text,
                                                  from: searchLocation, before: scanLimit)
            else {
                searchLocation = scanLimit
                break
            }

            guard found + 2 < scanLimit,
                  text.character(at: found + 1) == 0x60,
                  text.character(at: found + 2) == 0x60
            else {
                searchLocation = found + 1
                continue
            }

            let lineStart = fenceLineStart(in: text, at: found, lowerBound: scanStart)
            guard let lineStart else {
                // A literal "```" inside a line is not a delimiter.
                searchLocation = found + 1
                continue
            }

            if let start = state.markdownFenceStart {
                // Closing delimiter: the token runs through the end of this
                // line, so find the line break.
                let delimiterEnd = fenceLineEnd(in: text, at: found,
                                                before: scanLimit, scanner: &scanner)
                if let token = clippedToken(NSRange(location: start,
                                                    length: delimiterEnd - start),
                                            kind: .code, to: requested) {
                    result.append(token)
                }
                state.markdownFenceStart = nil
                searchLocation = max(delimiterEnd, found + 3)
            } else {
                // Opening delimiter: no token is emitted until it closes, so
                // the rest of this line does not need a line-break scan.
                state.markdownFenceStart = lineStart
                searchLocation = found + 3
            }
        }

        // An unterminated fence continues to the end of this chunk. The token
        // is clipped to the requested lines, so each chunk only re-colours its
        // own portion while the state carries the opening position forward.
        if let start = state.markdownFenceStart,
           let token = clippedToken(NSRange(location: start, length: scanLimit - start),
                                    kind: .code, to: requested) {
            result.append(token)
        }
        return result
    }

    /// Returns the start of the line containing `location` when everything
    /// between that line start and `location` is horizontal whitespace.
    ///
    /// Walking backwards over indentation is much cheaper than asking
    /// Foundation for `lineRange(for:)` at every backtick in a large document.
    /// `lowerBound` is a line boundary (the start of the scan or chunk).
    private func fenceLineStart(in text: NSString,
                                at location: Int,
                                lowerBound: Int) -> Int? {
        var index = location
        while index > lowerBound {
            let character = text.character(at: index - 1)
            if character == 0x0A || character == 0x0D { return index }
            if character != 0x20 && character != 0x09 { return nil }
            index -= 1
        }
        return index
    }

    /// End of the line containing `location`, including its CR/LF terminator.
    ///
    /// The scan is bounded by `scanLimit`, so the last line of a chunk can use
    /// the chunk boundary without looking outside the requested range.
    private func fenceLineEnd(in text: NSString,
                              at location: Int,
                              before scanLimit: Int,
                              scanner: inout ChunkScanner) -> Int {
        guard let lineBreak = scanner.firstLineBreak(in: text,
                                                     from: location,
                                                     before: scanLimit)
        else { return scanLimit }

        if text.character(at: lineBreak) == 0x0D,
           lineBreak + 1 < scanLimit,
           text.character(at: lineBreak + 1) == 0x0A {
            return lineBreak + 2
        }
        return lineBreak + 1
    }

    /// A small HTML state machine. Unlike `<[^>]+>`, it handles newlines and
    /// `>` characters inside quoted attribute values.
    ///
    /// It searches for the next `<` with `firstIndex(of:)` instead of visiting
    /// every character, so a local pass over large HTML does not scan the whole
    /// document in Swift. An open tag or comment is carried in `state`, so a
    /// full pass continues where the previous chunk stopped.
    private func scanHTML(in text: NSString,
                          clippedTo requested: NSRange,
                          state: inout State,
                          scanner: inout ChunkScanner) -> (tags: [Token], comments: [Token]) {
        var tags: [Token] = []
        var comments: [Token] = []
        let scanLimit = NSMaxRange(requested)
        var index = max(state.scanLocation, 0)

        while index < scanLimit {
            if let commentStart = state.htmlCommentStart {
                let closeSearch = NSRange(location: index, length: scanLimit - index)
                let close = text.range(of: "-->", options: [], range: closeSearch)
                let end = close.location == NSNotFound ? scanLimit : NSMaxRange(close)
                if let token = clippedToken(NSRange(location: commentStart,
                                                    length: end - commentStart),
                                            kind: .comment, to: requested) {
                    comments.append(token)
                }
                if close.location == NSNotFound {
                    state.htmlCommentStart = commentStart
                    index = scanLimit
                } else {
                    state.htmlCommentStart = nil
                    index = end
                }
                continue
            }

            if let tagStart = state.htmlTagStart {
                var quote = state.htmlTagQuote
                var closed = false
                while index < scanLimit {
                    let character = text.character(at: index)
                    if let activeQuote = quote {
                        if character == activeQuote { quote = nil }
                    } else if character == 0x22 || character == 0x27 { // " or '
                        quote = character
                    } else if character == 0x3E { // >
                        index += 1
                        closed = true
                        break
                    }
                    index += 1
                }
                if let token = clippedToken(NSRange(location: tagStart,
                                                    length: index - tagStart),
                                            kind: .tag, to: requested) {
                    tags.append(token)
                }
                if closed {
                    state.htmlTagStart = nil
                    state.htmlTagQuote = nil
                } else {
                    state.htmlTagQuote = quote
                    index = scanLimit
                }
                continue
            }

            // Neither a comment nor a tag is open: find the next tag start.
            guard let found = scanner.firstIndex(of: 0x3C, in: text,
                                                  from: index, before: scanLimit)
            else { break }

            if hasPrefix("<!--", at: found, in: text) {
                state.htmlCommentStart = found
                index = found + 4
            } else {
                state.htmlTagStart = found
                state.htmlTagQuote = nil
                index = found + 1
            }
        }
        return (tags, comments)
    }

    /// Reusable window over the document for the chunked ASCII searches.
    ///
    /// A local pass can call the scanner thousands of times (once per tag or
    /// fence delimiter). Re-reading a 64K chunk for every call would make the
    /// pass quadratic. The scanner keeps its last chunk and only loads the next
    /// one when a search runs past the window, so each character is copied once
    /// per pass.
    private struct ChunkScanner {
        private static let chunkSize = 64 * 1024
        private var buffer: [unichar] = []
        private var windowStart = 0
        private var windowCount = 0

        /// A fast ASCII search for `character` in a UTF-16 string.
        ///
        /// Foundation's `range(of:)`/`rangeOfCharacter(from:)` walk a 50 MB
        /// string in roughly half a second even when the character is absent.
        /// Reading fixed-size chunks and using `memchr` keeps this in
        /// single-digit milliseconds, without materialising the whole document
        /// as an array.
        mutating func firstIndex(of character: unichar,
                                 in text: NSString,
                                 from start: Int,
                                 before end: Int) -> Int? {
            let limit = min(end, text.length)
            guard start >= 0, start < limit else { return nil }

            var location = start
            while location < limit {
                loadWindow(containing: location, in: text, limit: limit)
                let offset = location - windowStart
                if let index = firstIndexInWindow(of: character, from: offset, in: text) {
                    return windowStart + index
                }
                location = windowStart + windowCount
            }
            return nil
        }

        /// First CR or LF at or after `start`, before `end`.
        mutating func firstLineBreak(in text: NSString,
                                     from start: Int,
                                     before end: Int) -> Int? {
            let limit = min(end, text.length)
            guard start >= 0, start < limit else { return nil }

            var location = start
            while location < limit {
                loadWindow(containing: location, in: text, limit: limit)
                let offset = location - windowStart
                let found = buffer.withUnsafeBufferPointer { characters -> Int? in
                    for index in offset..<windowCount {
                        let character = characters[index]
                        if character == 0x0A || character == 0x0D { return index }
                    }
                    return nil
                }
                if let found { return windowStart + found }
                location = windowStart + windowCount
            }
            return nil
        }

        private mutating func loadWindow(containing location: Int,
                                         in text: NSString,
                                         limit: Int) {
            if location >= windowStart, location < windowStart + windowCount { return }

            let count = min(Self.chunkSize, limit - location)
            guard count > 0 else { return }
            if buffer.count < count {
                buffer = [unichar](repeating: 0, count: count)
            }
            text.getCharacters(&buffer, range: NSRange(location: location, length: count))
            windowStart = location
            windowCount = count
        }

        /// Window-relative index of `character`, searching from `offset`.
        private func firstIndexInWindow(of character: unichar,
                                        from offset: Int,
                                        in text: NSString) -> Int? {
            guard offset < windowCount else { return nil }
            let stride = MemoryLayout<unichar>.size
            let byteCount = windowCount * stride

            return buffer.withUnsafeBytes { raw -> Int? in
                let base = raw.baseAddress!
                var searchFrom = offset
                while searchFrom < windowCount {
                    let byteOffset = searchFrom * stride
                    guard let match = memchr(base + byteOffset, Int32(character),
                                             byteCount - byteOffset)
                    else { return nil }
                    let index = (UnsafeRawPointer(match) - base) / stride
                    // `memchr` scans bytes, so a UTF-16 code unit can produce
                    // a false positive in an adjacent byte. Verify the unit.
                    if index < windowCount,
                       text.character(at: windowStart + index) == character {
                        return index
                    }
                    searchFrom = index + 1
                }
                return nil
            }
        }
    }

    private func hasPrefix(_ prefix: String, at location: Int, in text: NSString) -> Bool {
        let expected = prefix as NSString
        guard location + expected.length <= text.length else { return false }
        for offset in 0..<expected.length
        where text.character(at: location + offset) != expected.character(at: offset) {
            return false
        }
        return true
    }
}
