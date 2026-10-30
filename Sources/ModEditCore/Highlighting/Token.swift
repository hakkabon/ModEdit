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
    case keyword
    case number
    case `operator`
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
/// supply a `StatefulScanner` for constructs that cross line boundaries.
struct Tokenizer {
    private struct CompiledRule {
        let regex: NSRegularExpression
        let kind: TokenKind
    }

    /// Multiline state at a line boundary.
    ///
    /// A full-document pass carries one `State` across line-aligned chunks, so
    /// a stateful scanner visits every character once instead of re-scanning
    /// the prefix for each chunk. A local dirty-line pass instead starts from
    /// the nearest entry in `Checkpoints`, so it only replays the text between
    /// that snapshot and the dirty lines.
    struct State: Equatable, Sendable {
        /// UTF-16 offset up to which the state machine has consumed text.
        fileprivate(set) var scanLocation = 0
        /// Scanner-specific state. `nil` until a scanner has run (or for a
        /// format whose scanner is `nil`).
        fileprivate var scannerState: (any ScannerState)?

        init() {}

        static func == (lhs: State, rhs: State) -> Bool {
            guard lhs.scanLocation == rhs.scanLocation else { return false }
            switch (lhs.scannerState, rhs.scannerState) {
            case (nil, nil):
                return true
            case let (lhs?, rhs?):
                return lhs.isEqual(to: rhs)
            default:
                return false
            }
        }
    }

    /// A bounded cache of scanner snapshots at line boundaries.
    ///
    /// A snapshot is the complete `State` after consuming `[0, offset)`.
    /// Because stateful scanners are expected to be purely forward state
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
    /// Optional scan around the regex rules for multiline constructs.
    private let scanner: AnyStatefulScanner?

    /// - Parameters:
    ///   - rules: Local regex rules, lowest priority first.
    ///   - scanner: State machine for constructs that cross line boundaries.
    /// - Throws: if any rule's pattern is not a valid regular expression.
    init(rules: [HighlightRule], scanner: (any StatefulScanner)? = nil) throws {
        self.scanner = scanner?.erased()
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

        let scanned: ScannedTokens
        if let scanner {
            scanned = scanner.tokens(in: text,
                                     from: state.scanLocation,
                                     clippedTo: requested,
                                     state: &state.scannerState)
        } else {
            scanned = ScannedTokens()
        }
        var result: [Token] = scanned.leading

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
                    if let scope = scanned.ruleScope,
                       !scope.contains(where: { NSLocationInRange(range.location, $0) }) {
                        return
                    }
                    result.append(Token(range: range, kind: rule.kind))
                }
            }
        }

        // Opaque constructs (Markdown fences, HTML comments) win over the
        // regex rules by being applied last.
        result.append(contentsOf: scanned.trailing)

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
}
