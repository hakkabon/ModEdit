import Foundation

/// Markdown's stateful syntax: fenced code blocks.
///
/// An opening fence at the start of a line (after optional indentation) makes
/// every following line opaque until a matching fence closes it. Code tokens
/// are appended after the inline regex rules, so a heading-like line inside a
/// fence stays code-coloured.
struct MarkdownScanner: StatefulScanner {
    struct State: ScannerState, Equatable {
        /// Start of the line containing the open fence, or `nil` when outside a
        /// fence. Keeping the start lets a chunk emit the part of an
        /// unterminated fence that falls inside its own lines.
        var fenceStart: Int?
    }

    func initialState() -> State { State() }

    func tokens(in text: NSString,
                from scanStart: Int,
                clippedTo requested: NSRange,
                state: inout State) -> ScannedTokens {
        var result: [Token] = []
        var scanner = ChunkScanner()
        let scanLimit = NSMaxRange(requested)
        let start = max(scanStart, 0)
        var searchLocation = start

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

            let lineStart = ScannerSupport.lineStart(in: text, at: found, lowerBound: start)
            guard let lineStart else {
                // A literal "```" inside a line is not a delimiter.
                searchLocation = found + 1
                continue
            }

            if let fence = state.fenceStart {
                // Closing delimiter: the token runs through the end of this
                // line, so find the line break.
                let delimiterEnd = ScannerSupport.lineEnd(in: text, at: found,
                                                          before: scanLimit,
                                                          scanner: &scanner)
                if let token = ScannerSupport.clippedToken(NSRange(location: fence,
                                                                   length: delimiterEnd - fence),
                                                           kind: .code,
                                                           to: requested) {
                    result.append(token)
                }
                state.fenceStart = nil
                searchLocation = max(delimiterEnd, found + 3)
            } else {
                // Opening delimiter: no token is emitted until it closes, so
                // the rest of this line does not need a line-break scan.
                state.fenceStart = lineStart
                searchLocation = found + 3
            }
        }

        // An unterminated fence continues to the end of this chunk. The token
        // is clipped to the requested lines, so each chunk only re-colours its
        // own portion while the state carries the opening position forward.
        if let fence = state.fenceStart,
           let token = ScannerSupport.clippedToken(NSRange(location: fence,
                                                           length: scanLimit - fence),
                                                   kind: .code,
                                                   to: requested) {
            result.append(token)
        }
        return ScannedTokens(trailing: result)
    }
}
