import Darwin
import Foundation

/// Scanner state that must be carried across line-aligned chunks.
///
/// Each stateful scanner owns a small value type with the constructs that can
/// span lines (for example an open Markdown fence or an HTML tag). `Tokenizer`
/// stores the value type-erased so a format can supply its own scanner without
/// making the tokenizer generic.
protocol ScannerState: Sendable {
    /// Equality for a type-erased value, used by checkpoint tests and by
    /// `Tokenizer.State`'s `Equatable` conformance.
    func isEqual(to other: any ScannerState) -> Bool
}

extension ScannerState where Self: Equatable {
    func isEqual(to other: any ScannerState) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}

/// Tokens produced by a stateful scan, positioned around the regex rules.
///
/// The ordering is the format's priority scheme: `leading` tokens are applied
/// before regex matches (HTML tags contain attribute rules), and `trailing`
/// tokens are applied after them so opaque constructs such as Markdown fences
/// and HTML comments win.
struct ScannedTokens: Sendable {
    var leading: [Token] = []
    var trailing: [Token] = []
    /// When non-`nil`, a regex match is kept only when its start lies in one of
    /// these ranges. HTML uses this to scope attribute rules to tags; formats
    /// without a restrictive scanner leave it `nil`.
    var ruleScope: [NSRange]?

    init(leading: [Token] = [],
         trailing: [Token] = [],
         ruleScope: [NSRange]? = nil) {
        self.leading = leading
        self.trailing = trailing
        self.ruleScope = ruleScope
    }
}

/// A state machine for syntax whose meaning crosses line boundaries.
///
/// Scanners are pure values: all mutable state lives in `State`, which the
/// caller passes back on the next chunk. That is what lets `Tokenizer` cache a
/// checkpoint and resume a dirty-line pass in the middle of the document.
///
/// - Note: Implementations must only examine `[scanStart, NSMaxRange(requested))`
///   and must not change `requested`; the tokenizer clips both regex matches
///   and scanner tokens to the requested lines.
protocol StatefulScanner: Sendable {
    associatedtype State: ScannerState

    /// The state a scan starts with when no checkpoint is available.
    func initialState() -> State

    /// Tokens for one line-aligned chunk.
    ///
    /// - Parameters:
    ///   - scanStart: The first UTF-16 offset to consume. This is the previous
    ///     chunk's end, or the offset of a resumed checkpoint.
    ///   - requested: The line-aligned chunk being highlighted.
    ///   - state: Scanner-specific state; advanced to the end of `requested`.
    func tokens(in text: NSString,
                from scanStart: Int,
                clippedTo requested: NSRange,
                state: inout State) -> ScannedTokens

    /// Type-erases the state so `Tokenizer` can store heterogeneous scanners.
    /// A requirement (rather than an extension-only helper) keeps the call
    /// available on `any StatefulScanner`.
    func erased() -> AnyStatefulScanner
}

extension StatefulScanner {
    func erased() -> AnyStatefulScanner {
        AnyStatefulScanner(self)
    }
}

/// Type erasure for `StatefulScanner`, whose `State` is an associated type.
///
/// The existential is immutable and `Sendable`; the mutable state is boxed in
/// `Tokenizer.State`, so checkpoints can copy a complete snapshot.
struct AnyStatefulScanner: Sendable {
    private let scan: @Sendable (NSString, Int, NSRange, inout (any ScannerState)?) -> ScannedTokens

    init<S: StatefulScanner>(_ scanner: S) {
        self.scan = { text, scanStart, requested, state in
            var concrete = (state as? S.State) ?? scanner.initialState()
            let tokens = scanner.tokens(in: text,
                                        from: scanStart,
                                        clippedTo: requested,
                                        state: &concrete)
            state = concrete
            return tokens
        }
    }

    func tokens(in text: NSString,
                from scanStart: Int,
                clippedTo requested: NSRange,
                state: inout (any ScannerState)?) -> ScannedTokens {
        scan(text, scanStart, requested, &state)
    }
}

/// Reusable window over the document for chunked ASCII searches.
///
/// A local pass can call the scanner thousands of times (once per tag or fence
/// delimiter). Re-reading a 64K chunk for every call would make the pass
/// quadratic. The scanner keeps its last chunk and only loads the next one when
/// a search runs past the window, so each character is copied once per pass.
struct ChunkScanner {
    private static let chunkSize = 64 * 1024
    private var buffer: [unichar] = []
    private var windowStart = 0
    private var windowCount = 0

    /// A fast ASCII search for `character` in a UTF-16 string.
    ///
    /// Foundation's `range(of:)`/`rangeOfCharacter(from:)` walk a 50 MB string
    /// in roughly half a second even when the character is absent. Reading
    /// fixed-size chunks and using `memchr` keeps this in single-digit
    /// milliseconds, without materialising the whole document as an array.
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
                // `memchr` scans bytes, so a UTF-16 code unit can produce a
                // false positive in an adjacent byte. Verify the unit.
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

/// Shared geometry and clipping helpers for stateful scanners.
enum ScannerSupport {
    /// A scanner token clipped to the requested chunk, or `nil` when the
    /// construct lies completely outside it.
    static func clippedToken(_ range: NSRange,
                             kind: TokenKind,
                             to requested: NSRange) -> Token? {
        let clipped = NSIntersectionRange(range, requested)
        guard clipped.location != NSNotFound, clipped.length > 0 else { return nil }
        return Token(range: clipped, kind: kind)
    }

    /// Start of the line containing `location` when everything between that
    /// line start and `location` is horizontal whitespace.
    ///
    /// Walking backwards over indentation is much cheaper than asking
    /// Foundation for `lineRange(for:)` at every delimiter in a large document.
    /// `lowerBound` is a line boundary (the start of the scan or chunk).
    static func lineStart(in text: NSString,
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
    static func lineEnd(in text: NSString,
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

    static func hasPrefix(_ prefix: String, at location: Int, in text: NSString) -> Bool {
        let expected = prefix as NSString
        guard location + expected.length <= text.length else { return false }
        for offset in 0..<expected.length
        where text.character(at: location + offset) != expected.character(at: offset) {
            return false
        }
        return true
    }
}
