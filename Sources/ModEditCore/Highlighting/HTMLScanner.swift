import Foundation

/// HTML's stateful syntax: tags and comments.
///
/// Unlike `<[^>]+>`, this handles newlines and `>` characters inside quoted
/// attribute values. Tags are emitted before the regex rules so attribute-name
/// and string rules can be scoped to them; comments are emitted after them so
/// they stay opaque.
struct HTMLScanner: StatefulScanner {
    struct State: ScannerState, Equatable {
        var commentStart: Int?
        var tagStart: Int?
        var tagQuote: unichar?
    }

    func initialState() -> State { State() }

    func tokens(in text: NSString,
                from scanStart: Int,
                clippedTo requested: NSRange,
                state: inout State) -> ScannedTokens {
        var tags: [Token] = []
        var comments: [Token] = []
        var scanner = ChunkScanner()
        let scanLimit = NSMaxRange(requested)
        var index = max(scanStart, 0)

        while index < scanLimit {
            if let commentStart = state.commentStart {
                let closeSearch = NSRange(location: index, length: scanLimit - index)
                let close = text.range(of: "-->", options: [], range: closeSearch)
                let end = close.location == NSNotFound ? scanLimit : NSMaxRange(close)
                if let token = ScannerSupport.clippedToken(
                    NSRange(location: commentStart, length: end - commentStart),
                    kind: .comment,
                    to: requested) {
                    comments.append(token)
                }
                if close.location == NSNotFound {
                    state.commentStart = commentStart
                    index = scanLimit
                } else {
                    state.commentStart = nil
                    index = end
                }
                continue
            }

            if let tagStart = state.tagStart {
                var quote = state.tagQuote
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
                if let token = ScannerSupport.clippedToken(
                    NSRange(location: tagStart, length: index - tagStart),
                    kind: .tag,
                    to: requested) {
                    tags.append(token)
                }
                if closed {
                    state.tagStart = nil
                    state.tagQuote = nil
                } else {
                    state.tagQuote = quote
                    index = scanLimit
                }
                continue
            }

            // Neither a comment nor a tag is open: find the next tag start.
            guard let found = scanner.firstIndex(of: 0x3C, in: text,
                                                  from: index, before: scanLimit)
            else { break }

            if ScannerSupport.hasPrefix("<!--", at: found, in: text) {
                state.commentStart = found
                index = found + 4
            } else {
                state.tagStart = found
                state.tagQuote = nil
                index = found + 1
            }
        }
        return ScannedTokens(leading: tags,
                             trailing: comments,
                             ruleScope: tags.map(\.range))
    }
}
