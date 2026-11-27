import Foundation
import RenderedText

/// Renders the shared `RenderedText` projection as safe preview HTML.
///
/// The editor and the WebKit preview consume the same swift-markdown
/// projection. This adapter only maps block kinds, runs and semantic attributes
/// to HTML: it never re-parses Markdown and never trusts source text as markup.
/// All source text is escaped before tags are added, link targets are
/// restricted to `http`, `https` and `mailto`, and local images are emitted only
/// when the preview can supply a document base URL.
///
/// Source anchors are optional and one-based. Only this renderer and the
/// Markdown preview opt into them, so a hand-written HTML document can never
/// smuggle `data-source-line` attributes into the scroll bridge.
enum RenderedHTML {

    static func render(_ document: RenderedDocument,
                       sourceAnchors: Bool = false,
                       allowsLocalImages: Bool = false) -> String {
        let lines = LineStarts(source: document.source)
        let source = document.source as NSString
        var output: [String] = []

        for block in document.blocks {
            let html = render(block,
                              source: source,
                              lines: lines,
                              sourceAnchors: sourceAnchors,
                              allowsLocalImages: allowsLocalImages)
            if !html.isEmpty { output.append(html) }
        }
        return output.joined(separator: "\n")
    }

    // MARK: Blocks

    private static func render(_ block: RenderedBlock,
                               source: NSString,
                               lines: LineStarts,
                               sourceAnchors: Bool,
                               allowsLocalImages: Bool) -> String {
        let anchor = anchored(lines.line(at: block.sourceRange.lowerBound),
                              enabled: sourceAnchors)

        switch block.kind {
        case .blank:
            return ""
        case .heading:
            let level = block.runs.compactMap(\.attributes.headingLevel).first ?? 1
            let content = inlineHTML(block.runs, source: source,
                                     allowsLocalImages: allowsLocalImages,
                                     dropTrailingLineBreak: true)
            return "<h\(level)\(anchor)>\(content)</h\(level)>"
        case .paragraph:
            let content = inlineHTML(block.runs, source: source,
                                     allowsLocalImages: allowsLocalImages)
            return "<p\(anchor)>\(content)</p>"
        case .codeBlock:
            let code = codeText(block.runs)
            return "<pre\(anchor)><code>\(HTMLEscaping.escape(code))</code></pre>"
        case .list:
            return renderList(block.runs, source: source, lines: lines,
                              anchor: anchor, sourceAnchors: sourceAnchors,
                              allowsLocalImages: allowsLocalImages)
        case .blockQuote:
            return renderBlockQuote(block, source: source, lines: lines,
                                    anchor: anchor, sourceAnchors: sourceAnchors,
                                    allowsLocalImages: allowsLocalImages)
        case .table:
            return renderTable(block, source: source, anchor: anchor,
                               allowsLocalImages: allowsLocalImages)
        case .thematicBreak:
            return "<hr\(anchor)>"
        case .htmlBlock, .other:
            // Raw HTML is source text, not markup. Rendering it through the
            // inline path keeps every character escaped and visible.
            let content = inlineHTML(block.runs, source: source,
                                     allowsLocalImages: allowsLocalImages,
                                     dropTrailingLineBreak: true)
            return "<p\(anchor)>\(content)</p>"
        }
    }

    private static func anchored(_ line: Int, enabled: Bool) -> String {
        enabled ? " data-source-line=\"\(line)\"" : ""
    }

    // MARK: Inline content

    /// Maps runs to inline HTML.
    ///
    /// Consecutive runs that share a link destination are wrapped in one
    /// anchor, so emphasis and code inside a link label keep a single `href`.
    /// Unsafe destinations leave their label as plain escaped text. Image
    /// description runs are grouped into one `<img>` when the source can be
    /// loaded, with their styled words flattened into the `alt` attribute.
    private static func inlineHTML(_ runs: [RenderedRun],
                                   source: NSString,
                                   allowsLocalImages: Bool,
                                   dropTrailingLineBreak: Bool = false) -> String {
        var effective = runs
        if dropTrailingLineBreak {
            while let last = effective.last,
                  last.displayText.isEmpty
                    || last.role == .lineBreak
                    || last.role == .softBreak {
                effective.removeLast()
            }
        }

        var output = ""
        var openLink: String?
        var linkHTML = ""
        var openImageSource: String?
        var openImageAlt = ""
        var lastImageRun: RenderedRun?

        func flushLink() {
            guard let href = openLink else { return }
            output += "<a href=\"\(href)\">\(linkHTML)</a>"
            openLink = nil
            linkHTML = ""
        }

        func flushImage() {
            guard let src = openImageSource else { return }
            output += "<img src=\"\(src)\" alt=\"\(HTMLEscaping.escape(openImageAlt))\">"
            openImageSource = nil
            openImageAlt = ""
            lastImageRun = nil
        }

        for run in effective {
            guard !run.displayText.isEmpty else { continue }

            if run.attributes.isImage {
                // An image inside a link has its own source in the projection;
                // the outer link is not available, so never wrap the image text
                // in an unrelated anchor.
                flushLink()

                guard let imageSource = imageSource(run.attributes.linkDestination,
                                                    allowsLocalImages: allowsLocalImages)
                else {
                    flushImage()
                    output += styledInline(run)
                    continue
                }

                let beginsAnother = lastImageRun.map {
                    beginsAnotherImage(in: source,
                                       after: $0.sourceRange.upperBound,
                                       before: run.sourceRange.lowerBound)
                } ?? false
                if openImageSource != imageSource || beginsAnother {
                    flushImage()
                    openImageSource = imageSource
                }
                // A description-less image projects a visible "image"
                // placeholder for rendered editing. The preview keeps the
                // accessible attribute empty instead of narrating the
                // placeholder as the alt text.
                if run.role != .image {
                    openImageAlt += run.displayText
                }
                lastImageRun = run
                continue
            }

            flushImage()

            switch run.role {
            case .hiddenSyntax:
                continue
            case .lineBreak:
                flushLink()
                output += "<br>"
            case .tableSeparator:
                flushLink()
                output += " "
            default:
                let html = styledInline(run)
                if run.attributes.isLink,
                   let href = safeDestination(run.attributes.linkDestination) {
                    if openLink == href {
                        linkHTML += html
                    } else {
                        flushLink()
                        openLink = href
                        linkHTML = html
                    }
                } else {
                    flushLink()
                    output += html
                }
            }
        }
        flushImage()
        flushLink()
        return output
    }

    private static func styledInline(_ run: RenderedRun) -> String {
        var html = HTMLEscaping.escape(run.displayText)
        if run.attributes.isCode {
            html = "<code>\(html)</code>"
        }
        if run.attributes.isStrikethrough {
            html = "<del>\(html)</del>"
        }
        if run.attributes.isEmphasis {
            html = "<em>\(html)</em>"
        }
        if run.attributes.isStrong {
            html = "<strong>\(html)</strong>"
        }
        return html
    }

    /// Accepts only absolute `http`, `https` and `mailto` destinations.
    ///
    /// The returned value is escaped for a quoted attribute, so text escaping
    /// later in the pipeline cannot rewrite the URL. Images use
    /// `imageSource(_:allowsLocalImages:)` instead.
    private static func safeDestination(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let destination = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty,
              !destination.contains(where: \.isWhitespace),
              let colon = destination.firstIndex(of: ":")
        else { return nil }

        let scheme = destination[..<colon].lowercased()
        guard scheme == "http" || scheme == "https" || scheme == "mailto" else {
            return nil
        }
        return HTMLEscaping.escape(destination)
    }

    // MARK: Images

    /// Returns an escaped `src` value for an image the preview may load.
    ///
    /// `data:image` sources are self-contained and always allowed. Relative
    /// paths, absolute paths and local `file:` URLs need a document directory
    /// so the web view can resolve them; remote URLs and other schemes stay
    /// alt text, matching the preview's no-remote-loads policy.
    private static func imageSource(_ raw: String?,
                                    allowsLocalImages: Bool) -> String? {
        guard let raw else { return nil }
        let destination = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return nil }

        if destination.lowercased().hasPrefix("data:image/") {
            return HTMLEscaping.escape(destination)
        }
        guard allowsLocalImages, isLocalImageDestination(destination) else {
            return nil
        }
        return HTMLEscaping.escape(destination)
    }

    private static func isLocalImageDestination(_ destination: String) -> Bool {
        // A fragment cannot name an image, and `//host/path` is a remote URL
        // with the scheme supplied by the document.
        guard !destination.hasPrefix("#"), !destination.hasPrefix("//") else {
            return false
        }

        if let url = URL(string: destination), let scheme = url.scheme?.lowercased() {
            guard scheme == "file", url.isFileURL else { return false }
            // `file://host/path` can address another machine; only local file
            // URLs (including the localhost spelling) are preview resources.
            return url.host == nil || url.host == "" || url.host == "localhost"
        }
        return true
    }

    /// True when the source between two image runs starts another image.
    ///
    /// Formatted alt text (`![a **b**](x)`) produces several image runs with
    /// one destination, while two adjacent images (`![a](x)![b](x)`) produce
    /// the same pattern; the closing/opening syntax in the gap distinguishes
    /// them.
    private static func beginsAnotherImage(in source: NSString,
                                           after end: Int,
                                           before start: Int) -> Bool {
        guard start >= end, start <= source.length else { return true }
        return source.substring(
            with: NSRange(location: end, length: start - end)
        ).contains("![")
    }

    // MARK: Block quotes

    /// Block quotes normally contain inline text, but a quote may also hold a
    /// list. The projection flattens both into runs, so split at the first list
    /// marker: prose before it becomes a paragraph, and the rest is rebuilt
    /// with the same list renderer used for top-level lists.
    private static func renderBlockQuote(_ block: RenderedBlock,
                                         source: NSString,
                                         lines: LineStarts,
                                         anchor: String,
                                         sourceAnchors: Bool,
                                         allowsLocalImages: Bool) -> String {
        guard let firstMarker = block.runs.firstIndex(where: {
            $0.role == .listMarker
        }) else {
            let body = inlineHTML(block.runs, source: source,
                                  allowsLocalImages: allowsLocalImages,
                                  dropTrailingLineBreak: true)
            return "<blockquote\(anchor)>\(body)</blockquote>"
        }

        let list = renderList(Array(block.runs[firstMarker...]),
                              source: source,
                              lines: lines,
                              anchor: "",
                              sourceAnchors: sourceAnchors,
                              allowsLocalImages: allowsLocalImages)
        var body = ""
        let prose = inlineHTML(Array(block.runs[..<firstMarker]),
                               source: source,
                               allowsLocalImages: allowsLocalImages,
                               dropTrailingLineBreak: true)
        if !prose.isEmpty {
            body = "<p>\(prose)</p>\n"
        }
        return "<blockquote\(anchor)>\n\(body)\(list)\n</blockquote>"
    }

    // MARK: Lists

    private final class ListBuilder {
        let tag: String
        let indent: Int
        let start: Int?
        var items: [ItemBuilder] = []

        init(tag: String, indent: Int, start: Int?) {
            self.tag = tag
            self.indent = indent
            self.start = start
        }
    }

    private final class ItemBuilder {
        let anchorLine: Int
        let marker: ListMarker
        var runs: [RenderedRun] = []
        var children: [ListBuilder] = []

        init(anchorLine: Int, marker: ListMarker) {
            self.anchorLine = anchorLine
            self.marker = marker
        }
    }

    private static func renderList(_ runs: [RenderedRun],
                                   source: NSString,
                                   lines: LineStarts,
                                   anchor: String,
                                   sourceAnchors: Bool,
                                   allowsLocalImages: Bool) -> String {
        var roots: [ListBuilder] = []
        var stack: [ListBuilder] = []
        var currentItem: ItemBuilder?

        for run in runs {
            guard run.role == .listMarker else {
                currentItem?.runs.append(run)
                continue
            }
            guard let marker = run.attributes.listMarker else { continue }

            let tag: String
            let start: Int?
            switch marker {
            case .bullet, .task:
                tag = "ul"
                start = nil
            case .ordered(let number):
                tag = "ol"
                start = number
            }

            let indent = indentation(at: run.sourceRange.lowerBound, in: source)
            if stack.isEmpty {
                let list = ListBuilder(tag: tag, indent: indent, start: start)
                roots.append(list)
                stack = [list]
            } else if indent > stack[stack.count - 1].indent {
                let list = ListBuilder(tag: tag, indent: indent, start: start)
                stack[stack.count - 1].items.last?.children.append(list)
                stack.append(list)
            } else {
                while stack.count > 1, indent < stack[stack.count - 1].indent {
                    stack.removeLast()
                }
                if indent > stack[stack.count - 1].indent {
                    let list = ListBuilder(tag: tag, indent: indent, start: start)
                    stack[stack.count - 1].items.last?.children.append(list)
                    stack.append(list)
                } else if stack[stack.count - 1].tag != tag {
                    // A different list type at the same indentation starts a
                    // sibling list. Nested lists stay inside their parent item.
                    if stack.count == 1 {
                        let list = ListBuilder(tag: tag, indent: indent, start: start)
                        roots.append(list)
                        stack = [list]
                    } else {
                        let parent = stack[stack.count - 2]
                        stack.removeLast()
                        let list = ListBuilder(tag: tag, indent: indent, start: start)
                        parent.items.last?.children.append(list)
                        stack.append(list)
                    }
                }
            }

            let item = ItemBuilder(
                anchorLine: lines.line(at: run.sourceRange.lowerBound),
                marker: marker)
            stack[stack.count - 1].items.append(item)
            currentItem = item
        }

        return roots.enumerated().map { index, list in
            render(list,
                   anchor: index == 0 ? anchor : "",
                   includeContainerAnchor: index == 0,
                   source: source,
                   sourceAnchors: sourceAnchors,
                   allowsLocalImages: allowsLocalImages)
        }.joined(separator: "\n")
    }

    private static func render(_ list: ListBuilder,
                               anchor: String,
                               includeContainerAnchor: Bool,
                               source: NSString,
                               sourceAnchors: Bool,
                               allowsLocalImages: Bool) -> String {
        var start = ""
        if list.tag == "ol", let number = list.start, number != 1 {
            start = " start=\"\(number)\""
        }
        let opening = "<\(list.tag)\(includeContainerAnchor ? anchor : "")\(start)>"
        guard !list.items.isEmpty else { return opening + "</\(list.tag)>" }

        let items = list.items.map {
            render($0, source: source, sourceAnchors: sourceAnchors,
                   allowsLocalImages: allowsLocalImages)
        }.joined(separator: "\n")
        return opening + "\n" + items + "\n</\(list.tag)>"
    }

    private static func render(_ item: ItemBuilder,
                               source: NSString,
                               sourceAnchors: Bool,
                               allowsLocalImages: Bool) -> String {
        var body = inlineHTML(item.runs, source: source,
                              allowsLocalImages: allowsLocalImages,
                              dropTrailingLineBreak: true)
        switch item.marker {
        case .task(let checked):
            body = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> " + body
        case .bullet, .ordered:
            break
        }
        if !item.children.isEmpty {
            let children = item.children
                .map {
                    render($0, anchor: "", includeContainerAnchor: false,
                           source: source, sourceAnchors: sourceAnchors,
                           allowsLocalImages: allowsLocalImages)
                }
                .joined(separator: "\n")
            body += (body.isEmpty ? "" : "\n") + children
        }
        let anchor = sourceAnchors
            ? " data-source-line=\"\(item.anchorLine)\""
            : ""
        return "<li\(anchor)>\(body)</li>"
    }

    /// Leading whitespace columns before a marker, after any block-quote
    /// prefixes. This reconstructs nesting because the projection flattens
    /// list items into runs.
    private static func indentation(at offset: Int, in source: NSString) -> Int {
        let length = source.length
        let location = max(0, min(offset, length))
        let line = source.lineRange(for: NSRange(location: location, length: 0))
        let prefixLength = max(0, location - line.location)
        guard prefixLength > 0 else { return 0 }
        var prefix = source.substring(
            with: NSRange(location: line.location, length: prefixLength))
        if let quote = prefix.lastIndex(of: ">") {
            prefix = String(prefix[prefix.index(after: quote)...])
        }

        var width = 0
        for character in prefix {
            if character == "\t" {
                width += 4 - (width % 4)
            } else if character == " " {
                width += 1
            } else {
                break
            }
        }
        return width
    }

    // MARK: Tables

    private static func renderTable(_ block: RenderedBlock,
                                    source: NSString,
                                    anchor: String,
                                    allowsLocalImages: Bool) -> String {
        var rows: [[String]] = []
        var row: [String] = []
        var cell: [RenderedRun] = []
        var hasContent = false

        func flushCell() {
            row.append(inlineHTML(cell, source: source,
                                  allowsLocalImages: allowsLocalImages))
            cell = []
        }

        func flushRow() {
            guard !row.isEmpty || !cell.isEmpty else { return }
            flushCell()
            if hasContent { rows.append(row) }
            row = []
            hasContent = false
        }

        for run in block.runs {
            switch run.role {
            case .tableSeparator:
                flushCell()
            case .lineBreak:
                flushRow()
            case .hiddenSyntax:
                continue
            default:
                cell.append(run)
                if !run.displayText.isEmpty { hasContent = true }
            }
        }
        flushRow()

        guard !rows.isEmpty else { return "<table\(anchor)></table>" }

        let header = rows[0]
            .map { "<th>\($0)</th>" }
            .joined()
        var html = "<table\(anchor)>\n<thead><tr>\(header)</tr></thead>"
        if rows.count > 1 {
            let body = rows.dropFirst().map { row in
                "<tr>" + row.map { "<td>\($0)</td>" }.joined() + "</tr>"
            }.joined(separator: "\n")
            html += "\n<tbody>\n\(body)\n</tbody>"
        }
        html += "\n</table>"
        return html
    }

    // MARK: Code

    /// Visible code text with container/fence syntax removed and the single
    /// newline before the closing fence dropped.
    private static func codeText(_ runs: [RenderedRun]) -> String {
        var code = ""
        for run in runs {
            switch run.role {
            case .hiddenSyntax:
                continue
            case .lineBreak, .softBreak:
                code += "\n"
            default:
                code += run.displayText
            }
        }
        if code.hasSuffix("\r\n") {
            code.removeLast(2)
        } else if code.hasSuffix("\n") {
            code.removeLast()
        }
        return code
    }

    // MARK: Line numbers

    /// One-based line numbers for UTF-16 offsets, including CRLF and CR lines.
    private struct LineStarts {
        private let starts: [Int]

        init(source: String) {
            let text = source as NSString
            var starts: [Int] = [0]
            var index = 0
            while index < text.length {
                let character = text.character(at: index)
                if character == 0x0A {   // "\n"
                    starts.append(index + 1)
                } else if character == 0x0D {   // "\r" or "\r\n"
                    if index + 1 < text.length,
                       text.character(at: index + 1) == 0x0A {
                        index += 1
                    }
                    starts.append(index + 1)
                }
                index += 1
            }
            self.starts = starts
        }

        func line(at offset: Int) -> Int {
            var low = 0
            var high = starts.count - 1
            while low <= high {
                let middle = (low + high) / 2
                if starts[middle] <= offset {
                    low = middle + 1
                } else {
                    high = middle - 1
                }
            }
            return max(1, low)
        }
    }
}
