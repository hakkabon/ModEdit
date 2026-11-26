import Foundation
import Markdown

/// A Markdown projection renderer built on swift-markdown.
///
/// The parser supplies CommonMark/GFM structure and source ranges. This type
/// turns those ranges into blocks and runs that satisfy the projection
/// invariants: every source character belongs to exactly one run, hidden
/// syntax has zero display width, and visible text keeps its source span.
public struct MarkdownRenderer: RenderedTextRenderer, Sendable {
    public init() {}

    public func parse(_ source: String) -> MarkdownRenderTree {
        MarkdownRenderTree(source: source)
    }

    public func blocks(in tree: MarkdownRenderTree) -> [RenderedBlockDescriptor] {
        tree.descriptors
    }

    public func render(_ descriptor: RenderedBlockDescriptor,
                       in tree: MarkdownRenderTree) -> RenderedBlock {
        guard tree.units.indices.contains(descriptor.payload) else {
            let text = tree.sourceText(in: descriptor.sourceRange)
            return RenderedBlock(
                id: descriptor.id,
                kind: descriptor.kind,
                sourceRange: descriptor.sourceRange,
                runs: [RenderedRun(sourceRange: descriptor.sourceRange, displayText: text)])
        }

        let unit = tree.units[descriptor.payload]
        let runs = renderRuns(for: unit, in: tree)
        return RenderedBlock(
            id: descriptor.id,
            kind: unit.kind,
            sourceRange: unit.range,
            runs: runs.isEmpty
                ? [RenderedRun(sourceRange: unit.range, displayText: "", role: .hiddenSyntax)]
                : runs)
    }

    /// Parses and renders a complete Markdown source.
    public func render(_ source: String) throws -> RenderedDocument {
        try RenderedDocument(source: source, renderer: self)
    }

    // MARK: Blocks

    private func renderRuns(for unit: MarkdownRenderTree.Unit,
                            in tree: MarkdownRenderTree) -> [RenderedRun] {
        let range = unit.range
        let inherited = RenderedAttributes()

        switch unit.kind {
        case .heading:
            var attributes = inherited
            attributes.headingLevel = (unit.node as? Heading)?.level ?? 1
            return renderInlineBlock(
                unit.node,
                range: range,
                attributes: attributes,
                trailingNewlineVisible: true,
                tree: tree)
        case .paragraph:
            return renderInlineBlock(
                unit.node,
                range: range,
                attributes: inherited,
                trailingNewlineVisible: false,
                tree: tree)
        case .list:
            return renderList(unit.node, range: range, inherited: inherited, tree: tree)
        case .blockQuote:
            return renderBlockQuote(unit.node, range: range, inherited: inherited, tree: tree)
        case .codeBlock:
            return renderCodeBlock(
                unit.node as? CodeBlock,
                range: range,
                inherited: inherited,
                tree: tree)
        case .table:
            return renderTable(
                unit.node as? Table,
                range: range,
                inherited: inherited,
                tree: tree)
        case .thematicBreak:
            return renderThematicBreak(range: range, inherited: inherited, tree: tree)
        case .htmlBlock:
            return renderHTMLBlock(range: range, inherited: inherited, tree: tree)
        case .blank:
            return renderBlank(range, inherited: inherited, tree: tree)
        case .other:
            return renderRaw(range: range, inherited: inherited, tree: tree)
        }
    }

    private func renderChildBlock(_ node: any Markup,
                                  range: Range<Int>,
                                  inherited: RenderedAttributes,
                                  tree: MarkdownRenderTree) -> [RenderedRun] {
        if let heading = node as? Heading {
            var attributes = inherited
            attributes.headingLevel = heading.level
            return renderInlineBlock(
                node,
                range: range,
                attributes: attributes,
                trailingNewlineVisible: true,
                tree: tree)
        }
        if node is Paragraph {
            return renderInlineBlock(
                node,
                range: range,
                attributes: inherited,
                trailingNewlineVisible: false,
                tree: tree)
        }
        if node is UnorderedList || node is OrderedList {
            return renderList(node, range: range, inherited: inherited, tree: tree)
        }
        if node is BlockQuote {
            return renderBlockQuote(node, range: range, inherited: inherited, tree: tree)
        }
        if let code = node as? CodeBlock {
            return renderCodeBlock(code, range: range, inherited: inherited, tree: tree)
        }
        if let table = node as? Table {
            return renderTable(table, range: range, inherited: inherited, tree: tree)
        }
        if node is ThematicBreak {
            return renderThematicBreak(range: range, inherited: inherited, tree: tree)
        }
        if node is HTMLBlock {
            return renderHTMLBlock(range: range, inherited: inherited, tree: tree)
        }
        return renderRaw(range: range, inherited: inherited, tree: tree)
    }

    // MARK: Inline blocks

    private struct InlineSpan {
        let range: Range<Int>
        let text: String
        let role: RenderedRunRole
        let attributes: RenderedAttributes
    }

    private func renderInlineBlock(_ node: (any Markup)?,
                                   range: Range<Int>,
                                   attributes: RenderedAttributes,
                                   trailingNewlineVisible: Bool,
                                   tree: MarkdownRenderTree) -> [RenderedRun] {
        guard let node else {
            return renderRaw(range: range, inherited: attributes, tree: tree)
        }
        var spans: [InlineSpan] = []
        collectInline(node, attributes: attributes, into: &spans, tree: tree)
        return combine(
            spans: spans,
            range: range,
            trailingNewlineVisible: trailingNewlineVisible,
            attributes: attributes,
            tree: tree)
    }

    private func combine(spans: [InlineSpan],
                         range: Range<Int>,
                         trailingNewlineVisible: Bool,
                         attributes: RenderedAttributes,
                         tree: MarkdownRenderTree) -> [RenderedRun] {
        let ordered = spans.sorted {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.upperBound > $1.range.upperBound
        }

        var runs: [RenderedRun] = []
        var cursor = range.lowerBound
        for span in ordered {
            guard span.range.lowerBound >= range.lowerBound,
                  span.range.upperBound <= range.upperBound,
                  span.range.lowerBound >= cursor,
                  !span.range.isEmpty else { continue }
            if span.range.lowerBound > cursor {
                runs += inlineGapRuns(
                    cursor..<span.range.lowerBound,
                    attributes: attributes,
                    tree: tree)
            }
            runs.append(RenderedRun(
                sourceRange: span.range,
                displayText: span.text,
                role: span.role,
                attributes: span.attributes))
            cursor = span.range.upperBound
        }

        guard cursor < range.upperBound else { return runs }
        if trailingNewlineVisible,
           let newline = tree.offsets.firstNewline(in: cursor..<range.upperBound) {
            if newline.index > cursor {
                runs += hiddenRuns(cursor..<newline.index, attributes: attributes)
            }
            runs.append(RenderedRun(
                sourceRange: newline.index..<(newline.index + newline.length),
                displayText: "\n",
                role: .lineBreak,
                attributes: attributes))
            let after = newline.index + newline.length
            if after < range.upperBound {
                runs += hiddenRuns(after..<range.upperBound, attributes: attributes)
            }
        } else {
            runs += inlineGapRuns(
                cursor..<range.upperBound,
                attributes: attributes,
                tree: tree)
        }
        return runs
    }

    private func collectInline(_ node: any Markup,
                               attributes: RenderedAttributes,
                               into spans: inout [InlineSpan],
                               tree: MarkdownRenderTree) {
        var cursor = tree.offsets.range(for: node.range)?.lowerBound ?? 0
        collectInline(
            node,
            attributes: attributes,
            into: &spans,
            searchCursor: &cursor,
            tree: tree)
    }

    private func collectInline(_ node: any Markup,
                               attributes: RenderedAttributes,
                               into spans: inout [InlineSpan],
                               searchCursor: inout Int,
                               tree: MarkdownRenderTree) {
        if let text = node as? Text {
            guard let range = resolvedTextRange(
                for: text,
                searchStart: searchCursor,
                tree: tree) else { return }
            appendTextSegments(
                in: range,
                expectedText: text.string,
                attributes: attributes,
                into: &spans,
                tree: tree)
            searchCursor = max(searchCursor, range.upperBound)
            return
        }

        if let code = node as? InlineCode {
            guard let range = tree.offsets.range(for: code.range) else { return }
            var codeAttributes = attributes
            codeAttributes.isCode = true
            spans.append(InlineSpan(
                range: range,
                text: code.code.isEmpty ? tree.sourceText(in: range) : code.code,
                role: .code,
                attributes: codeAttributes))
            searchCursor = max(searchCursor, range.upperBound)
            return
        }

        if let html = node as? InlineHTML {
            guard let range = resolvedInlineHTMLRange(
                for: html,
                searchStart: searchCursor,
                tree: tree) else { return }
            var htmlAttributes = attributes
            htmlAttributes.isHTML = true
            appendVisibleSpans(
                in: range,
                role: .html,
                attributes: htmlAttributes,
                into: &spans,
                tree: tree)
            searchCursor = max(searchCursor, range.upperBound)
            return
        }

        if node is SoftBreak || node is LineBreak { return }

        var childAttributes = attributes
        if node is Emphasis { childAttributes.isEmphasis = true }
        if node is Strong { childAttributes.isStrong = true }
        if node is Strikethrough { childAttributes.isStrikethrough = true }
        if let link = node as? Link {
            childAttributes.isLink = true
            childAttributes.linkDestination = link.destination
        }
        if let image = node as? Image {
            childAttributes.isImage = true
            childAttributes.linkDestination = image.source
            if image.isEmpty, let range = tree.offsets.range(for: image.range) {
                spans.append(InlineSpan(
                    range: range,
                    text: "image",
                    role: .image,
                    attributes: childAttributes))
                searchCursor = max(searchCursor, range.upperBound)
                return
            }
        }
        if node is Link, node.isEmpty { return }

        if node.isEmpty {
            // Container markup has no text of its own. Empty headings, links
            // and emphasis are pure syntax, so let the gap renderer hide them
            // rather than displaying their delimiters.
            if node is Heading || node is Paragraph || node is Emphasis ||
                node is Strong || node is Strikethrough || node is Link ||
                node is Image {
                if let raw = tree.offsets.range(for: node.range) {
                    searchCursor = max(searchCursor, raw.upperBound)
                }
                return
            }
            guard let range = tree.offsets.range(for: node.range) else { return }
            spans.append(InlineSpan(
                range: range,
                text: tree.sourceText(in: range),
                role: .text,
                attributes: childAttributes))
            searchCursor = max(searchCursor, range.upperBound)
            return
        }

        for child in node.children {
            collectInline(
                child,
                attributes: childAttributes,
                into: &spans,
                searchCursor: &searchCursor,
                tree: tree)
        }
        if let raw = tree.offsets.range(for: node.range) {
            searchCursor = max(searchCursor, raw.upperBound)
        }
    }

    /// Resolves a `Text` node's source range.
    ///
    /// swift-markdown occasionally reports an inline range on the wrong line
    /// (for example, the text after a backslash hard break, or a lazy block
    /// quote continuation). When the reported range does not contain the
    /// node's text, search for the text from the current inline cursor.
    private func resolvedTextRange(for text: Text,
                                   searchStart: Int,
                                   tree: MarkdownRenderTree) -> Range<Int>? {
        let raw = tree.offsets.range(for: text.range)
        let expected = text.string

        if let raw, !raw.isEmpty {
            let rawText = tree.sourceText(in: raw)
            if rawText == expected {
                return raw
            }
            // Entities and backslash escapes are intentionally different from
            // the decoded string; their ranges are trustworthy.
            if rawText.contains("&") || rawText.contains("\\") {
                return raw
            }
            // A truncated suffix or prefix is the shifted-range signature.
            guard expected.hasSuffix(rawText) || rawText.hasSuffix(expected) ||
                    expected.hasPrefix(rawText) else {
                return raw
            }
        }

        if let found = findPlainText(expected, from: searchStart, tree: tree) {
            return found
        }
        return raw
    }

    private func findPlainText(_ needle: String,
                               from start: Int,
                               tree: MarkdownRenderTree) -> Range<Int>? {
        guard !needle.isEmpty else { return nil }
        let source = tree.source as NSString
        let lower = max(0, min(start, source.length))
        let searchRange = NSRange(location: lower, length: source.length - lower)
        let found = source.range(of: needle, options: [], range: searchRange)
        guard found.location != NSNotFound else { return nil }
        return found.location..<(found.location + found.length)
    }

    /// Resolves an inline HTML node's source range.
    ///
    /// cmark returns the literal HTML with normalized line endings but can
    /// report an end position one character short when the tag spans lines
    /// (usually dropping the closing `>`). Match the literal against the
    /// source, treating CRLF and CR as LF, to recover the exact span.
    private func resolvedInlineHTMLRange(for html: InlineHTML,
                                         searchStart: Int,
                                         tree: MarkdownRenderTree) -> Range<Int>? {
        let raw = tree.offsets.range(for: html.range)
        let expected = html.rawHTML
        if let raw, !expected.isEmpty, tree.sourceText(in: raw) == expected {
            return raw
        }

        let start = raw?.lowerBound ?? max(0, min(searchStart, tree.offsets.length))
        if let end = normalizedMatchEnd(expected, from: start, tree: tree) {
            return start..<end
        }

        var candidate = max(0, min(searchStart, tree.offsets.length))
        while candidate < tree.offsets.length {
            if let end = normalizedMatchEnd(expected, from: candidate, tree: tree) {
                return candidate..<end
            }
            candidate += 1
        }
        return raw
    }

    private func normalizedMatchEnd(_ expected: String,
                                    from start: Int,
                                    tree: MarkdownRenderTree) -> Int? {
        guard !expected.isEmpty else { return nil }
        let source = tree.source as NSString
        let expectedUnits = Array(expected.utf16)
        var sourceIndex = start
        var expectedIndex = 0

        while expectedIndex < expectedUnits.count {
            guard sourceIndex < source.length else { return nil }
            let unit = source.character(at: sourceIndex)
            if unit == 0x0D {
                guard expectedUnits[expectedIndex] == 0x0A else { return nil }
                sourceIndex += 1
                if sourceIndex < source.length,
                   source.character(at: sourceIndex) == 0x0A {
                    sourceIndex += 1
                }
                expectedIndex += 1
            } else {
                guard unit == expectedUnits[expectedIndex] else { return nil }
                sourceIndex += 1
                expectedIndex += 1
            }
        }
        return sourceIndex
    }

    private func trimmingTrailingWhitespace(_ string: String) -> String {
        var end = string.endIndex
        while end > string.startIndex {
            let previous = string.index(before: end)
            let character = string[previous]
            guard character == " " || character == "\t" else { break }
            end = previous
        }
        return String(string[..<end])
    }

    private func appendTextSegments(in range: Range<Int>,
                                    expectedText: String,
                                    attributes: RenderedAttributes,
                                    into spans: inout [InlineSpan],
                                    tree: MarkdownRenderTree) {
        let trimsLineEnd = tree.offsets.newlineLength(at: range.upperBound) > 0
            || range.upperBound == tree.offsets.length
        let segments = decodeTextSegments(in: range, tree: tree)
        let decoded = segments.map(\.text).joined()
        let comparable = trimsLineEnd
            ? trimmingTrailingWhitespace(decoded)
            : decoded
        let comparableExpected = trimsLineEnd
            ? trimmingTrailingWhitespace(expectedText)
            : expectedText

        // `Text.string` is the parser's authoritative decoding. If it differs
        // from the segment decoder (for example an HTML entity outside the
        // built-in name table), keep the decoded text as one monotonic
        // substitution instead of displaying the raw entity.
        if !expectedText.isEmpty, comparable != comparableExpected {
            spans.append(InlineSpan(
                range: range,
                text: expectedText,
                role: .text,
                attributes: attributes))
            return
        }

        for segment in segments {
            let raw = tree.sourceText(in: segment.range)
            let isPlain = raw == segment.text

            // CommonMark removes trailing spaces at a line end. Keep the source
            // range as hidden syntax so runs still tile the block.
            if isPlain,
               trimsLineEnd,
               segment.range.upperBound == range.upperBound {
                var trim = 0
                let text = raw as NSString
                while trim < text.length {
                    let character = text.character(at: text.length - trim - 1)
                    guard character == 0x20 || character == 0x09 else { break }
                    trim += 1
                }
                if trim > 0 {
                    let visibleEnd = segment.range.upperBound - trim
                    if segment.range.lowerBound < visibleEnd {
                        let visible = text.substring(
                            with: NSRange(
                                location: 0,
                                length: text.length - trim))
                        spans.append(InlineSpan(
                            range: segment.range.lowerBound..<visibleEnd,
                            text: visible,
                            role: .text,
                            attributes: attributes))
                    }
                    spans.append(InlineSpan(
                        range: visibleEnd..<segment.range.upperBound,
                        text: "",
                        role: .hiddenSyntax,
                        attributes: attributes))
                    continue
                }
            }

            spans.append(InlineSpan(
                range: segment.range,
                text: segment.text,
                role: .text,
                attributes: attributes))
        }
    }

    // MARK: Lists

    private func renderList(_ node: (any Markup)?,
                            range: Range<Int>,
                            inherited: RenderedAttributes,
                            tree: MarkdownRenderTree) -> [RenderedRun] {
        guard let node else {
            return renderRaw(range: range, inherited: inherited, tree: tree)
        }
        let ordered = node is OrderedList
        var runs: [RenderedRun] = []
        var cursor = range.lowerBound

        for item in node.children {
            guard let rawItemRange = tree.offsets.range(for: item.range) else { continue }
            let itemStart = max(cursor, max(range.lowerBound, rawItemRange.lowerBound))
            let itemEnd = min(range.upperBound, max(itemStart, rawItemRange.upperBound))
            guard itemEnd > itemStart else { continue }
            if itemStart > cursor {
                runs += blockGapRuns(cursor..<itemStart, inherited: inherited, tree: tree)
            }

            let itemRange = itemStart..<itemEnd
            let firstChildStart = item.children.first(where: { _ in true })
                .flatMap { tree.offsets.range(for: $0.range)?.lowerBound }
                ?? itemEnd
            let markerEnd = min(itemEnd, max(itemStart, firstChildStart))
            if markerEnd > itemStart {
                runs.append(listMarkerRun(
                    item: item,
                    range: itemStart..<markerEnd,
                    ordered: ordered,
                    inherited: inherited,
                    tree: tree))
            }

            var itemCursor = markerEnd
            for child in item.children {
                guard let raw = tree.offsets.range(for: child.range) else { continue }
                let childStart = max(itemCursor, max(itemRange.lowerBound, raw.lowerBound))
                let childEnd = min(itemRange.upperBound, max(childStart, raw.upperBound))
                guard childEnd > childStart else { continue }
                if childStart > itemCursor {
                    runs += blockGapRuns(
                        itemCursor..<childStart,
                        inherited: inherited,
                        tree: tree)
                }
                runs += renderChildBlock(
                    child,
                    range: childStart..<childEnd,
                    inherited: inherited,
                    tree: tree)
                itemCursor = childEnd
            }
            if itemCursor < itemEnd {
                runs += blockGapRuns(itemCursor..<itemEnd, inherited: inherited, tree: tree)
            }
            cursor = itemEnd
        }

        if cursor < range.upperBound {
            runs += blockGapRuns(cursor..<range.upperBound, inherited: inherited, tree: tree)
        }
        return runs
    }

    private func listMarkerRun(item: any Markup,
                               range: Range<Int>,
                               ordered: Bool,
                               inherited: RenderedAttributes,
                               tree: MarkdownRenderTree) -> RenderedRun {
        var attributes = inherited
        let text: String

        if let listItem = item as? ListItem, let checkbox = listItem.checkbox {
            switch checkbox {
            case .checked:
                text = "☑ "
                attributes.listMarker = .task(checked: true)
            case .unchecked:
                text = "☐ "
                attributes.listMarker = .task(checked: false)
            }
        } else if ordered {
            let raw = tree.sourceText(in: range).trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = raw.prefix(while: { $0.isNumber })
            let number = Int(digits) ?? 1
            let suffix = raw.contains(")") ? ") " : ". "
            text = digits.isEmpty ? raw : "\(digits)\(suffix)"
            attributes.listMarker = .ordered(number)
        } else {
            text = "• "
            attributes.listMarker = .bullet
        }

        return RenderedRun(
            sourceRange: range,
            displayText: text,
            role: .listMarker,
            attributes: attributes)
    }

    // MARK: Block quotes

    private func renderBlockQuote(_ node: (any Markup)?,
                                  range: Range<Int>,
                                  inherited: RenderedAttributes,
                                  tree: MarkdownRenderTree) -> [RenderedRun] {
        guard let node else {
            return renderRaw(range: range, inherited: inherited, tree: tree)
        }
        var attributes = inherited
        attributes.isBlockQuote = true

        var runs: [RenderedRun] = []
        var cursor = range.lowerBound
        for child in node.children {
            guard let raw = tree.offsets.range(for: child.range) else { continue }
            let start = max(cursor, max(range.lowerBound, raw.lowerBound))
            let end = min(range.upperBound, max(start, raw.upperBound))
            guard end > start else { continue }
            if start > cursor {
                runs += blockGapRuns(cursor..<start, inherited: attributes, tree: tree)
            }
            runs += renderChildBlock(
                child,
                range: start..<end,
                inherited: attributes,
                tree: tree)
            cursor = end
        }
        if cursor < range.upperBound {
            runs += blockGapRuns(cursor..<range.upperBound, inherited: attributes, tree: tree)
        }
        return runs
    }

    // MARK: Code

    private func renderCodeBlock(_ code: CodeBlock?,
                                 range: Range<Int>,
                                 inherited: RenderedAttributes,
                                 tree: MarkdownRenderTree) -> [RenderedRun] {
        guard let code else {
            return renderRaw(range: range, inherited: inherited, tree: tree)
        }
        var attributes = inherited
        attributes.isCode = true
        attributes.codeLanguage = code.language

        // A code block whose content begins with backticks can still be an
        // indented code block. The parser gives both forms the same
        // `CodeBlock` node, so inspect the source and the parsed code below to
        // tell them apart.
        let lineStart = tree.offsets.lineStart(containing: range.lowerBound)
        let linePrefix = tree.sourceText(in: lineStart..<range.lowerBound)

        let firstLineEnd = tree.offsets.lineEnd(after: range.lowerBound, limitedTo: range.upperBound)
        let firstLine = tree.sourceText(in: range.lowerBound..<firstLineEnd)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fenceCharacter = firstLine.first,
              fenceCharacter == "`" || fenceCharacter == "~" else {
            return renderIndentedCode(
                range: range,
                linePrefix: linePrefix,
                attributes: attributes,
                tree: tree)
        }
        let fenceCount = firstLine.prefix(while: { $0 == fenceCharacter }).count
        guard fenceCount >= 3 else {
            return renderIndentedCode(
                range: range,
                linePrefix: linePrefix,
                attributes: attributes,
                tree: tree)
        }

        let openingEnd = firstLineEnd
        var closingStart: Int?
        var cursor = openingEnd
        while cursor < range.upperBound {
            let end = tree.offsets.lineEnd(after: cursor, limitedTo: range.upperBound)
            let line = cursor..<end
            let contentStart = codeContentStart(
                in: line,
                hidingPrefix: linePrefix,
                tree: tree)
            if isClosingFence(
                tree.sourceText(in: contentStart..<end),
                character: fenceCharacter,
                count: fenceCount) {
                closingStart = cursor
                break
            }
            cursor = end
        }
        let contentEnd = closingStart ?? range.upperBound
        if isIndentedCode(
            code,
            openingLine: firstLine,
            closingStart: closingStart,
            linePrefix: linePrefix,
            character: fenceCharacter,
            count: fenceCount) {
            return renderIndentedCode(
                range: range,
                linePrefix: linePrefix,
                attributes: attributes,
                tree: tree)
        }

        var runs: [RenderedRun] = []
        if range.lowerBound < openingEnd {
            runs += hiddenRuns(range.lowerBound..<openingEnd, attributes: attributes)
        }
        var contentCursor = openingEnd
        while contentCursor < contentEnd {
            let end = tree.offsets.lineEnd(after: contentCursor, limitedTo: contentEnd)
            runs += codeLineRuns(
                contentCursor..<end,
                hidingPrefix: linePrefix,
                attributes: attributes,
                tree: tree)
            contentCursor = end
        }
        if let closingStart, closingStart < range.upperBound {
            runs += hiddenRuns(closingStart..<range.upperBound, attributes: attributes)
        }
        if runs.isEmpty {
            runs += hiddenRuns(range, attributes: attributes)
        }
        return runs
    }

    private func renderIndentedCode(range: Range<Int>,
                                    linePrefix: String,
                                    attributes: RenderedAttributes,
                                    tree: MarkdownRenderTree) -> [RenderedRun] {
        var runs: [RenderedRun] = []
        for line in tree.offsets.lineRanges(in: range) {
            // The parser's range starts after the indentation of the first
            // line, but continuation lines still carry the full prefix.
            let prefix = line.lowerBound == range.lowerBound ? "" : linePrefix
            runs += codeLineRuns(
                line,
                hidingPrefix: prefix,
                attributes: attributes,
                tree: tree)
        }
        return runs.isEmpty ? hiddenRuns(range, attributes: attributes) : runs
    }

    /// Emits one code line, hiding the container marker and indentation that
    /// precede the code content.
    private func codeLineRuns(_ line: Range<Int>,
                              hidingPrefix prefix: String,
                              attributes: RenderedAttributes,
                              tree: MarkdownRenderTree) -> [RenderedRun] {
        let contentStart = codeContentStart(
            in: line,
            hidingPrefix: prefix,
            tree: tree)
        var runs: [RenderedRun] = []
        if contentStart > line.lowerBound {
            runs += hiddenRuns(line.lowerBound..<contentStart, attributes: attributes)
        }
        if contentStart < line.upperBound {
            runs += visibleRuns(
                in: contentStart..<line.upperBound,
                role: .code,
                attributes: attributes,
                tree: tree)
        }
        return runs
    }

    private func codeContentStart(in line: Range<Int>,
                                  hidingPrefix prefix: String,
                                  tree: MarkdownRenderTree) -> Int {
        guard !prefix.isEmpty, line.lowerBound < line.upperBound else {
            return line.lowerBound
        }
        let text = tree.sourceText(in: line)
        if text.hasPrefix(prefix) {
            return line.lowerBound + prefix.utf16.count
        }

        if prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
            let target = trailingIndentationWidth(of: prefix)
            var width = 0
            var offset = line.lowerBound
            for character in text {
                if character == "\t" {
                    width += 4 - (width % 4)
                } else if character == " " {
                    width += 1
                } else {
                    break
                }
                offset += character.utf16.count
                if width >= target { break }
            }
            return offset
        }

        // Block quote markers and a list marker on the first line do not
        // necessarily repeat on continuation lines. Hide the shared prefix,
        // then use the remaining container width to strip continuation
        // indentation without swallowing code content.
        var commonCharacters = 0
        var commonUTF16 = 0
        for (left, right) in zip(text, prefix) {
            guard left == right else { break }
            commonCharacters += 1
            commonUTF16 += String(left).utf16.count
        }
        let remaining = max(0, prefix.utf16.count - commonUTF16)
        var offset = line.lowerBound + commonUTF16
        var width = 0
        for character in text.dropFirst(commonCharacters) {
            if character == "\t" {
                width += 4 - (width % 4)
            } else if character == " " {
                width += 1
            } else {
                break
            }
            offset += character.utf16.count
            if width >= remaining { break }
        }
        return offset
    }

    /// Whether a fence-looking code block is actually indented code.
    ///
    /// A closed fenced block never contains its own closing fence, while an
    /// indented code block that starts with a fence line includes that line in
    /// its parsed content. The indentation check keeps a fenced block whose
    /// first content line happens to repeat its opening line from being
    /// mistaken for indented code.
    private func isIndentedCode(_ code: CodeBlock,
                                openingLine: String,
                                closingStart: Int?,
                                linePrefix: String,
                                character: Character,
                                count: Int) -> Bool {
        let normalized = code.code
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        if closingStart != nil,
           let lastLine = lines.last(where: { !$0.isEmpty }),
           isClosingFence(String(lastLine), character: character, count: count) {
            return true
        }

        let firstCodeLine = lines.first.map(String.init) ?? ""
        return firstCodeLine.trimmingCharacters(in: .whitespaces) == openingLine
            && trailingIndentationWidth(of: linePrefix) >= 4
    }

    /// The column width of the whitespace run at the end of `prefix`.
    ///
    /// Container markers such as `>`, `-`, or `1.` may precede the block's
    /// content, so only the whitespace after the last marker counts toward the
    /// block's indentation. Tabs advance to the next multiple of four columns.
    private func trailingIndentationWidth(of prefix: String) -> Int {
        var width = 0
        for character in prefix.reversed() {
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

    private func isClosingFence(_ line: String,
                                character: Character,
                                count: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let prefix = trimmed.prefix(while: { $0 == character })
        guard prefix.count >= count else { return false }
        return trimmed.dropFirst(prefix.count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    // MARK: Tables

    private func renderTable(_ table: Table?,
                             range: Range<Int>,
                             inherited: RenderedAttributes,
                             tree: MarkdownRenderTree) -> [RenderedRun] {
        guard let table else {
            return renderRaw(range: range, inherited: inherited, tree: tree)
        }

        var cellSpans: [InlineSpan] = []
        collectTableCells(table, inherited: inherited, into: &cellSpans, tree: tree)

        var spans = cellSpans
        let lines = tree.offsets.lineRanges(in: range)
        let delimiterLines = Set(lines.filter {
            isTableDelimiterLine(tree.sourceText(in: $0))
        })

        // The delimiter row (and its newline) is pure syntax. Hiding the whole
        // line keeps the newline from being projected as a soft break.
        for line in delimiterLines {
            spans.append(InlineSpan(
                range: line,
                text: "",
                role: .hiddenSyntax,
                attributes: inherited))
        }

        for line in lines where !delimiterLines.contains(line) {
            let newline = tree.offsets.firstNewline(in: line)
            if let newline {
                spans.append(InlineSpan(
                    range: newline.index..<(newline.index + newline.length),
                    text: "\n",
                    role: .lineBreak,
                    attributes: inherited))
            }

            let contentEnd = newline?.index ?? line.upperBound
            var index = line.lowerBound
            let text = tree.source as NSString
            while index < contentEnd {
                if text.character(at: index) == 0x7C,
                   !isEscapedPipe(at: index, in: text),
                   !cellSpans.contains(where: { $0.range.contains(index) }) {
                    let before = tree.sourceText(in: line.lowerBound..<index)
                        .trimmingCharacters(in: .whitespaces)
                    let after = tree.sourceText(in: (index + 1)..<contentEnd)
                        .trimmingCharacters(in: .whitespaces)
                    if !before.isEmpty, !after.isEmpty {
                        spans.append(InlineSpan(
                            range: index..<(index + 1),
                            text: "\t",
                            role: .tableSeparator,
                            attributes: inherited))
                    }
                }
                index += 1
            }
        }

        return combine(
            spans: spans,
            range: range,
            trailingNewlineVisible: false,
            attributes: inherited,
            tree: tree)
    }

    private func collectTableCells(_ node: any Markup,
                                   inherited: RenderedAttributes,
                                   into spans: inout [InlineSpan],
                                   tree: MarkdownRenderTree) {
        if node is Table.Cell {
            for child in node.children {
                collectInline(child, attributes: inherited, into: &spans, tree: tree)
            }
            return
        }
        for child in node.children {
            collectTableCells(child, inherited: inherited, into: &spans, tree: tree)
        }
    }

    private func isTableDelimiterLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { character in
            character == "|" || character == "-" || character == ":" ||
                character == " " || character == "\t"
        }
    }

    /// True when the pipe at `index` is escaped by an odd number of preceding
    /// backslashes, as in a GFM table cell containing a literal `|`. Such a
    /// pipe is content, not a cell boundary (and not the closing delimiter).
    private func isEscapedPipe(at index: Int, in text: NSString) -> Bool {
        var backslashes = 0
        var cursor = index - 1
        while cursor >= 0, text.character(at: cursor) == 0x5C {
            backslashes += 1
            cursor -= 1
        }
        return backslashes % 2 == 1
    }

    // MARK: Leaf blocks

    private func renderThematicBreak(range: Range<Int>,
                                     inherited: RenderedAttributes,
                                     tree: MarkdownRenderTree) -> [RenderedRun] {
        // A following blank line can extend the parser's block range through
        // the trailing newline. The newline is a line break, not part of the
        // horizontal rule.
        let newline = tree.offsets.firstNewline(in: range)
        let contentEnd = newline?.index ?? range.upperBound
        var runs: [RenderedRun] = []
        if range.lowerBound < contentEnd {
            runs.append(RenderedRun(
                sourceRange: range.lowerBound..<contentEnd,
                displayText: String(repeating: "─", count: max(3, contentEnd - range.lowerBound)),
                role: .thematicBreak,
                attributes: inherited))
        }
        if let newline {
            runs += newlineRuns(
                in: newline.index..<range.upperBound,
                inherited: inherited,
                tree: tree)
        }
        return runs
    }

    private func renderHTMLBlock(range: Range<Int>,
                                 inherited: RenderedAttributes,
                                 tree: MarkdownRenderTree) -> [RenderedRun] {
        var attributes = inherited
        attributes.isHTML = true
        return visibleRuns(
            in: range,
            role: .html,
            attributes: attributes,
            tree: tree)
    }

    private func renderRaw(range: Range<Int>,
                           inherited: RenderedAttributes,
                           tree: MarkdownRenderTree) -> [RenderedRun] {
        visibleRuns(
            in: range,
            role: .text,
            attributes: inherited,
            tree: tree)
    }

    // MARK: Gaps

    private func inlineGapRuns(_ range: Range<Int>,
                               attributes: RenderedAttributes,
                               tree: MarkdownRenderTree) -> [RenderedRun] {
        guard !range.isEmpty else { return [] }
        var runs: [RenderedRun] = []
        var cursor = range.lowerBound
        var plainStart = cursor

        while cursor < range.upperBound {
            let newlineLength = tree.offsets.newlineLength(at: cursor)
            if newlineLength > 0 {
                if plainStart < cursor {
                    runs += hiddenRuns(plainStart..<cursor, attributes: attributes)
                }
                let isHard = tree.offsets.isHardBreak(newlineAt: cursor)
                runs.append(RenderedRun(
                    sourceRange: cursor..<(cursor + newlineLength),
                    displayText: isHard ? "\n" : " ",
                    role: isHard ? .lineBreak : .softBreak,
                    attributes: attributes))
                cursor += newlineLength
                plainStart = cursor
            } else {
                cursor += 1
            }
        }
        if plainStart < range.upperBound {
            runs += hiddenRuns(plainStart..<range.upperBound, attributes: attributes)
        }
        return runs
    }

    private func blockGapRuns(_ range: Range<Int>,
                              inherited: RenderedAttributes,
                              tree: MarkdownRenderTree) -> [RenderedRun] {
        guard !range.isEmpty else { return [] }
        var runs: [RenderedRun] = []
        for line in tree.offsets.lineRanges(in: range) {
            let text = tree.sourceText(in: line)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isReferenceDefinition(text) {
                runs += hiddenRuns(line, attributes: inherited)
            } else {
                runs += newlineRuns(in: line, inherited: inherited, tree: tree)
            }
        }
        return runs
    }

    private func renderBlank(_ range: Range<Int>,
                             inherited: RenderedAttributes,
                             tree: MarkdownRenderTree) -> [RenderedRun] {
        guard !range.isEmpty else { return [] }
        var runs: [RenderedRun] = []
        for line in tree.offsets.lineRanges(in: range) {
            let raw = tree.sourceText(in: line)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if isReferenceDefinition(trimmed) {
                runs += hiddenRuns(line, attributes: inherited)
            } else if trimmed.isEmpty {
                runs += newlineRuns(in: line, inherited: inherited, tree: tree)
            } else {
                runs += visibleRuns(
                    in: line,
                    role: .text,
                    attributes: inherited,
                    tree: tree)
            }
        }
        return runs
    }

    private func newlineRuns(in line: Range<Int>,
                             inherited: RenderedAttributes,
                             tree: MarkdownRenderTree) -> [RenderedRun] {
        guard !line.isEmpty else { return [] }
        var runs: [RenderedRun] = []
        var cursor = line.lowerBound
        var plainStart = cursor
        while cursor < line.upperBound {
            let length = tree.offsets.newlineLength(at: cursor)
            if length > 0 {
                if plainStart < cursor {
                    runs += hiddenRuns(plainStart..<cursor, attributes: inherited)
                }
                runs.append(RenderedRun(
                    sourceRange: cursor..<(cursor + length),
                    displayText: "\n",
                    role: .lineBreak,
                    attributes: inherited))
                cursor += length
                plainStart = cursor
            } else {
                cursor += 1
            }
        }
        if plainStart < line.upperBound {
            runs += hiddenRuns(plainStart..<line.upperBound, attributes: inherited)
        }
        return runs
    }

    private struct VisibleSegment {
        let range: Range<Int>
        let text: String
        let isNewline: Bool
    }

    /// Splits visible source into text and normalized newline segments.
    ///
    /// The projection displays one `\n` for every CRLF, CR or LF source
    /// newline. Splitting the newline into its own run keeps the UTF-16 map
    /// exact across the substitution.
    private func visibleSegments(in range: Range<Int>,
                                 tree: MarkdownRenderTree) -> [VisibleSegment] {
        guard !range.isEmpty else { return [] }
        var segments: [VisibleSegment] = []
        var cursor = range.lowerBound
        var textStart = cursor

        while cursor < range.upperBound {
            let length = tree.offsets.newlineLength(at: cursor)
            if length > 0 {
                if textStart < cursor {
                    segments.append(VisibleSegment(
                        range: textStart..<cursor,
                        text: tree.sourceText(in: textStart..<cursor),
                        isNewline: false))
                }
                segments.append(VisibleSegment(
                    range: cursor..<(cursor + length),
                    text: "\n",
                    isNewline: true))
                cursor += length
                textStart = cursor
            } else {
                cursor += 1
            }
        }

        if textStart < range.upperBound {
            segments.append(VisibleSegment(
                range: textStart..<range.upperBound,
                text: tree.sourceText(in: textStart..<range.upperBound),
                isNewline: false))
        }
        return segments
    }

    private func appendVisibleSpans(in range: Range<Int>,
                                    role: RenderedRunRole,
                                    attributes: RenderedAttributes,
                                    into spans: inout [InlineSpan],
                                    tree: MarkdownRenderTree) {
        for segment in visibleSegments(in: range, tree: tree) {
            spans.append(InlineSpan(
                range: segment.range,
                text: segment.text,
                role: segment.isNewline ? .lineBreak : role,
                attributes: attributes))
        }
    }

    private func visibleRuns(in range: Range<Int>,
                             role: RenderedRunRole,
                             attributes: RenderedAttributes,
                             tree: MarkdownRenderTree) -> [RenderedRun] {
        visibleSegments(in: range, tree: tree).map { segment in
            RenderedRun(
                sourceRange: segment.range,
                displayText: segment.text,
                role: segment.isNewline ? .lineBreak : role,
                attributes: attributes)
        }
    }

    private func hiddenRuns(_ range: Range<Int>,
                            attributes: RenderedAttributes = RenderedAttributes()) -> [RenderedRun] {
        guard !range.isEmpty else { return [] }
        return [RenderedRun(
            sourceRange: range,
            displayText: "",
            role: .hiddenSyntax,
            attributes: attributes)]
    }

    private func isReferenceDefinition(_ line: String) -> Bool {
        guard line.hasPrefix("["),
              let close = line.firstIndex(of: "]") else { return false }
        let after = line.index(after: close)
        return after < line.endIndex && line[after] == ":"
    }

    // MARK: Text decoding

    private func decodeTextSegments(in range: Range<Int>,
                                    tree: MarkdownRenderTree) -> [(range: Range<Int>, text: String)] {
        let source = tree.source as NSString
        var segments: [(range: Range<Int>, text: String)] = []
        var plainStart = range.lowerBound
        var index = range.lowerBound

        while index < range.upperBound {
            let character = source.character(at: index)

            if character == 0x5C, index + 1 < range.upperBound,
               isASCIIPunctuation(source.character(at: index + 1)) {
                if plainStart < index {
                    segments.append((
                        range: plainStart..<index,
                        text: source.substring(with: NSRange(
                            location: plainStart,
                            length: index - plainStart))))
                }
                let escaped = source.substring(with: NSRange(location: index + 1, length: 1))
                segments.append((range: index..<(index + 2), text: escaped))
                index += 2
                plainStart = index
                continue
            }

            if character == 0x26,
               let semicolon = entityEnd(from: index + 1, limit: range.upperBound, source: source),
               let decoded = decodeEntity(source.substring(
                    with: NSRange(location: index, length: semicolon - index + 1))) {
                if plainStart < index {
                    segments.append((
                        range: plainStart..<index,
                        text: source.substring(with: NSRange(
                            location: plainStart,
                            length: index - plainStart))))
                }
                segments.append((range: index..<(semicolon + 1), text: decoded))
                index = semicolon + 1
                plainStart = index
                continue
            }

            index += 1
        }

        if plainStart < range.upperBound {
            segments.append((
                range: plainStart..<range.upperBound,
                text: source.substring(with: NSRange(
                    location: plainStart,
                    length: range.upperBound - plainStart))))
        }
        return segments
    }

    private func entityEnd(from start: Int, limit: Int, source: NSString) -> Int? {
        var index = start
        var count = 0
        while index < limit, count < 32 {
            let character = source.character(at: index)
            if character == 0x3B { return index }
            guard character == 0x23 || character == 0x78 || character == 0x58 ||
                    (character >= 0x30 && character <= 0x39) ||
                    (character >= 0x41 && character <= 0x5A) ||
                    (character >= 0x61 && character <= 0x7A) else { return nil }
            index += 1
            count += 1
        }
        return nil
    }

    private func decodeEntity(_ entity: String) -> String? {
        guard entity.hasPrefix("&"), entity.hasSuffix(";") else { return nil }
        let body = String(entity.dropFirst().dropLast())
        guard !body.isEmpty else { return nil }

        if body.hasPrefix("#") {
            let number = body.dropFirst()
            let scalarValue: UInt32?
            if number.hasPrefix("x") || number.hasPrefix("X") {
                scalarValue = UInt32(number.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(number, radix: 10)
            }
            guard let scalarValue, let scalar = UnicodeScalar(scalarValue) else { return nil }
            return String(scalar)
        }

        return Self.namedEntities[body]
    }

    private func isASCIIPunctuation(_ character: unichar) -> Bool {
        switch character {
        case 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A,
             0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E,
             0x3F, 0x40, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60, 0x7B, 0x7C,
             0x7D, 0x7E:
            return true
        default:
            return false
        }
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "copy": "©", "reg": "®", "trade": "™",
        "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘",
        "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«",
        "raquo": "»", "times": "×", "divide": "÷", "plusmn": "±",
        "deg": "°", "micro": "µ", "para": "¶", "sect": "§",
        "middot": "·", "bull": "•", "dagger": "†", "Dagger": "‡",
        "permil": "‰", "euro": "€", "pound": "£", "yen": "¥",
        "cent": "¢", "larr": "←", "rarr": "→", "uarr": "↑",
        "darr": "↓", "harr": "↔", "alpha": "α", "beta": "β",
        "gamma": "γ", "delta": "δ", "epsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "omicron": "ο", "pi": "π", "rho": "ρ", "sigma": "σ",
        "tau": "τ", "upsilon": "υ", "phi": "φ", "chi": "χ",
        "psi": "ψ", "omega": "ω", "Alpha": "Α", "Beta": "Β",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ",
        "Omega": "Ω", "infin": "∞", "ne": "≠", "le": "≤",
        "ge": "≥", "sum": "∑", "prod": "∏", "radic": "√",
        "part": "∂", "nabla": "∇", "isin": "∈", "notin": "∉",
        "cap": "∩", "cup": "∪", "and": "∧", "or": "∨",
        "there4": "∴", "sim": "∼", "cong": "≅", "asymp": "≈",
        "equiv": "≡", "sub": "⊂", "sup": "⊃", "sube": "⊆",
        "supe": "⊇", "oplus": "⊕", "otimes": "⊗", "perp": "⊥",
        "sdot": "⋅", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊",
        "rfloor": "⌋", "lang": "〈", "rang": "〉",
    ]
}

/// The parse product for `MarkdownRenderer`.
///
/// The tree owns the swift-markdown AST, the UTF-16 offset index, and one
/// descriptor per top-level block or gap. It is not `Sendable`; renderers are
/// used on the thread that owns the document.
public struct MarkdownRenderTree {
    public let source: String
    public let descriptors: [RenderedBlockDescriptor]

    let units: [Unit]
    let offsets: SourceOffsetIndex

    init(source: String) {
        let offsets = SourceOffsetIndex(source)
        let document = Document(parsing: source)
        let length = source.utf16.count

        var units: [Unit] = []
        var cursor = 0
        for child in document.children {
            guard let rawRange = offsets.range(for: child.range) else { continue }
            let start = max(cursor, max(0, rawRange.lowerBound))
            let end = min(length, max(start, rawRange.upperBound))
            guard end > start else { continue }
            if start > cursor {
                units.append(Unit(kind: .blank, range: cursor..<start, node: nil))
            }
            units.append(Unit(kind: Self.kind(for: child), range: start..<end, node: child))
            cursor = end
        }
        if cursor < length {
            units.append(Unit(kind: .blank, range: cursor..<length, node: nil))
        }

        self.source = source
        self.offsets = offsets
        self.units = units
        self.descriptors = Self.makeDescriptors(source: source, units: units)
    }

    func sourceText(in range: Range<Int>) -> String {
        offsets.text(in: range)
    }

    struct Unit {
        let kind: RenderedBlockKind
        let range: Range<Int>
        let node: (any Markup)?
    }

    private struct BlockKey: Hashable {
        let kind: RenderedBlockKind
        let contentHash: UInt64
    }

    private static func makeDescriptors(source: String,
                                        units: [Unit]) -> [RenderedBlockDescriptor] {
        let text = source as NSString
        var counts: [BlockKey: Int] = [:]
        var descriptors: [RenderedBlockDescriptor] = []

        for (index, unit) in units.enumerated() {
            let sourceText = text.substring(with: NSRange(
                location: unit.range.lowerBound,
                length: unit.range.count))
            let contentHash = StableHash.fnv1a(sourceText)
            let key = BlockKey(kind: unit.kind, contentHash: contentHash)
            let occurrence = counts[key, default: 0]
            counts[key] = occurrence + 1

            descriptors.append(RenderedBlockDescriptor(
                id: BlockID(
                    kind: unit.kind,
                    contentHash: contentHash,
                    occurrence: occurrence),
                kind: unit.kind,
                sourceRange: unit.range,
                contentHash: contentHash,
                occurrence: occurrence,
                payload: index))
        }
        return descriptors
    }

    private static func kind(for node: any Markup) -> RenderedBlockKind {
        if node is Heading { return .heading }
        if node is Paragraph { return .paragraph }
        if node is UnorderedList || node is OrderedList { return .list }
        if node is BlockQuote { return .blockQuote }
        if node is CodeBlock { return .codeBlock }
        if node is Table { return .table }
        if node is ThematicBreak { return .thematicBreak }
        if node is HTMLBlock { return .htmlBlock }
        return .other
    }
}
