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

    /// Private-use character delimiting code-span placeholders.
    private static let marker = "\u{E000}"

    static func inline(_ text: String) -> String {
        var s = HTMLEscaping.escape(text)

        // Code spans first, parked behind placeholders so that emphasis and
        // link syntax inside them is left alone.
        var codeSpans: [String] = []
        s = s.replacingMatches(of: #"`([^`\n]+)`"#) { groups in
            codeSpans.append("<code>\(groups[1])</code>")
            return "\(marker)\(codeSpans.count - 1)\(marker)"
        }

        s = s.replacingMatches(of: #"\[([^\]\n]+)\]\(([^)\s]+)\)"#) { groups in
            let scheme = groups[2].lowercased()
            guard scheme.hasPrefix("http://") || scheme.hasPrefix("https://") || scheme.hasPrefix("mailto:")
            else { return groups[0] }   // e.g. javascript: stays inert text
            // The URL was already escaped above, so it is safe inside quotes.
            return "<a href=\"\(groups[2])\">\(groups[1])</a>"
        }
        s = s.replacingMatches(of: #"(?s)\*\*(?=\S)(.+?)(?<=\S)\*\*"#) { "<strong>\($0[1])</strong>" }
        s = s.replacingMatches(of: #"\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*"#) { "<em>\($0[1])</em>" }

        return s.replacingMatches(of: "\(marker)(\\d+)\(marker)") { groups in
            guard let index = Int(groups[1]), codeSpans.indices.contains(index) else { return "" }
            return codeSpans[index]
        }
    }
}
