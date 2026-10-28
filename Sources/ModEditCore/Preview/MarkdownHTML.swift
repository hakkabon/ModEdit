import Foundation

/// A small Markdown-to-HTML converter for the live preview.
///
/// Supported: ATX headings (`#`..`######`), paragraphs, fenced code blocks,
/// block quotes, bullet and numbered lists (flat), and the inline forms
/// `` `code` ``, `**bold**`, `*italic*` and `[text](http(s)/mailto URL)`.
///
/// Not supported (yet): nested lists, tables, images, setext headings, HTML
/// pass-through, `_underscore_` emphasis. For full CommonMark/GFM, replace this
/// with `swift-markdown` (see the README roadmap).
///
/// ## Safety
///
/// All text is HTML-escaped *before* any markup is introduced, link targets are
/// restricted to `http`, `https` and `mailto`, and code content is never
/// re-interpreted. Raw HTML in the source is shown as text, not executed.
enum MarkdownHTML {

    static func render(_ source: String) -> String {
        // "\r\n" is a single Character in Swift, so normalise before splitting.
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var out: [String] = []
        var paragraph: [String] = []
        var listTag: String?
        var inFence = false
        var fence: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>" + inline(paragraph.joined(separator: "\n")) + "</p>")
            paragraph.removeAll()
        }
        func closeList() {
            guard let tag = listTag else { return }
            out.append("</\(tag)>")
            listTag = nil
        }
        func flushFence() {
            out.append("<pre><code>" + HTMLEscaping.escape(fence.joined(separator: "\n")) + "</code></pre>")
            fence.removeAll()
        }

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence {
                    flushFence()
                    inFence = false
                } else {
                    flushParagraph()
                    closeList()
                    inFence = true
                }
                continue
            }
            if inFence {
                fence.append(line)
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                closeList()
                continue
            }
            if let level = headingLevel(line) {
                flushParagraph()
                closeList()
                let title = String(line.dropFirst(level).drop(while: { $0 == " " }))
                out.append("<h\(level)>\(inline(title))</h\(level)>")
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                closeList()
                let quoted = String(line.dropFirst().drop(while: { $0 == " " }))
                out.append("<blockquote>\(inline(quoted))</blockquote>")
                continue
            }
            if let item = listItem(line) {
                flushParagraph()
                if listTag != item.tag {
                    closeList()
                    out.append("<\(item.tag)>")
                    listTag = item.tag
                }
                out.append("<li>\(inline(item.content))</li>")
                continue
            }
            closeList()
            paragraph.append(line)
        }
        if inFence { flushFence() }   // unterminated fence: still show the code
        flushParagraph()
        closeList()
        return out.joined(separator: "\n")
    }

    // MARK: Blocks

    /// `1...6` if `line` is an ATX heading (hashes followed by a space).
    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> (tag: String, content: String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return ("ul", String(line.dropFirst(marker.count)))
        }
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return ("ol", String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    // MARK: Inline

    /// Private-use character delimiting protected spans.
    private static let marker = "\u{E000}"

    static func inline(_ text: String) -> String {
        // Code spans are extracted first so link syntax inside them stays
        // literal. Links are extracted next and their destinations are parked
        // behind placeholders, so the emphasis pass can never edit a URL.
        let code = replaceCodeSpans(in: text)
        let links = replaceLinks(in: code.text, codeSpans: code.spans)

        var s = HTMLEscaping.escape(links.text)
        s = applyEmphasis(to: s)
        s = restorePlaceholders(in: s, kind: "C", values: code.spans)
        s = restorePlaceholders(in: s, kind: "L", values: links.spans)
        return s
    }

    private static func placeholder(_ kind: String, _ index: Int) -> String {
        "\(marker)\(kind)\(index)\(marker)"
    }

    private static func replaceCodeSpans(in text: String) -> (text: String, spans: [String]) {
        var spans: [String] = []
        let result = text.replacingMatches(of: #"`([^`\n]+)`"#) { groups in
            spans.append("<code>\(HTMLEscaping.escape(groups[1]))</code>")
            return placeholder("C", spans.count - 1)
        }
        return (result, spans)
    }

    /// Replaces `[label](destination)` with protected link markup.
    ///
    /// A scanner rather than a regular expression: destinations may contain
    /// balanced parentheses (for example `/wiki/Foo_(bar)`), and emphasis must
    /// not see the generated `href` attribute.
    private static func replaceLinks(in text: String,
                                     codeSpans: [String]) -> (text: String, spans: [String]) {
        var result = ""
        var spans: [String] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "[" else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }

            let labelStart = text.index(after: index)
            guard let closeBracket = text[labelStart...].firstIndex(where: {
                      $0 == "]" || $0 == "\n"
                  }),
                  text[closeBracket] == "]",
                  labelStart < closeBracket
            else {
                result.append(text[index])
                index = labelStart
                continue
            }

            let afterBracket = text.index(after: closeBracket)
            guard afterBracket < text.endIndex, text[afterBracket] == "(" else {
                result.append(text[index])
                index = labelStart
                continue
            }

            var cursor = text.index(after: afterBracket)
            var depth = 0
            var destination = ""
            var closingParenthesis: String.Index?

            while cursor < text.endIndex {
                let character = text[cursor]
                if character == "\n" { break }
                if character == "(" {
                    depth += 1
                    destination.append(character)
                } else if character == ")" {
                    if depth == 0 {
                        closingParenthesis = cursor
                        break
                    }
                    depth -= 1
                    destination.append(character)
                } else {
                    destination.append(character)
                }
                cursor = text.index(after: cursor)
            }

            guard let closingParenthesis,
                  let href = safeLinkDestination(destination)
            else {
                // Not a valid link: leave the source text intact. The normal
                // escaping pass will display it literally.
                result.append(text[index])
                index = labelStart
                continue
            }

            let label = String(text[labelStart..<closeBracket])
            let labelHTML = renderLinkLabel(label, codeSpans: codeSpans)
            spans.append("<a href=\"\(href)\">\(labelHTML)</a>")
            result += placeholder("L", spans.count - 1)
            index = text.index(after: closingParenthesis)
        }

        return (result, spans)
    }

    private static func safeLinkDestination(_ raw: String) -> String? {
        let destination = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty,
              !destination.contains(where: \.isWhitespace),
              let colon = destination.firstIndex(of: ":")
        else { return nil }

        let scheme = destination[..<colon].lowercased()
        guard scheme == "http" || scheme == "https" || scheme == "mailto" else {
            return nil
        }

        // Escaping the attribute value here means emphasis and escaping later
        // cannot alter the URL.
        return HTMLEscaping.escape(destination)
    }

    private static func renderLinkLabel(_ label: String,
                                        codeSpans: [String]) -> String {
        var s = HTMLEscaping.escape(label)
        s = applyEmphasis(to: s)
        return restorePlaceholders(in: s, kind: "C", values: codeSpans)
    }

    private static func applyEmphasis(to text: String) -> String {
        var s = text.replacingMatches(of: #"(?s)\*\*(?=\S)(.+?)(?<=\S)\*\*"#) {
            "<strong>\($0[1])</strong>"
        }
        s = s.replacingMatches(of: #"\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*"#) {
            "<em>\($0[1])</em>"
        }
        return s
    }

    private static func restorePlaceholders(in text: String,
                                            kind: String,
                                            values: [String]) -> String {
        guard !values.isEmpty else { return text }
        let pattern = "\(marker)\(kind)(\\d+)\(marker)"
        return text.replacingMatches(of: pattern) { groups in
            guard let index = Int(groups[1]), values.indices.contains(index) else {
                return ""
            }
            return values[index]
        }
    }
}
