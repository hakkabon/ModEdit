import Foundation
import RenderedText

/// One run of the rendered projection, as seen by the editor host.
///
/// Unlike `RenderedRun`, this records how the run should be presented in the
/// editor: visible text, collapsed syntax, or the raw source of the line that
/// currently contains the caret.
struct RenderedEditorSpan: Hashable, Sendable {
    /// UTF-16 source range. Spans tile the source exactly like their runs.
    let sourceRange: Range<Int>
    /// Collapsed syntax outside the active line. These characters remain in
    /// storage so offsets, undo and saving are unchanged.
    let isHidden: Bool
    /// Part of the line under the caret. The editor shows the literal source
    /// here so markup can be edited without switching modes.
    let isRaw: Bool
    /// The text the projection wants displayed. It may differ from the source
    /// spelling for entities, escapes, list markers, thematic breaks and
    /// inline code.
    let displayText: String
    /// Whether the host should substitute `displayText` for the source
    /// spelling. Raw and hidden spans never substitute.
    let isSubstitution: Bool
    let role: RenderedRunRole
    let attributes: RenderedAttributes

    var displayLength: Int {
        if isHidden { return 0 }
        return isSubstitution ? displayText.utf16.count : sourceRange.count
    }
}

/// One source range whose visible spelling differs from its rendered display
/// text. The host replaces glyphs without touching `NSTextStorage`.
struct RenderedEditorSubstitution: Hashable, Sendable {
    let sourceRange: Range<Int>
    let displayText: String
    let role: RenderedRunRole

    var displayLength: Int { displayText.utf16.count }
}

/// A Markdown image whose destination the editor may draw as a real attachment.
///
/// `sourceRange` covers the complete `![alt](destination)` syntax, not just the
/// alt-text run the projection exposes. `isStandalone` is true when the image
/// is the only content on its line, which is the case the editor can lay out at
/// its natural aspect ratio without disturbing surrounding text.
struct RenderedEditorImage: Hashable, Sendable {
    let sourceRange: Range<Int>
    let destination: String
    let altText: String
    let isStandalone: Bool
}

/// The Markdown projection used by live rendered editing.
///
/// The editor keeps the Markdown source in `NSTextStorage`. This value owns the
/// platform-neutral projection and answers two questions the host cannot:
/// which source ranges are syntax that can be collapsed, and how a caret moves
/// through the document when collapsed syntax has no display width.
///
/// Display width is *not* the same as raw source width. `nextSourceOffset`
/// therefore walks display offsets outside the caret's line, while movement
/// inside the caret's line is plain source movement because that line shows
/// its markup.
struct RenderedEditorPresentation: Sendable {
    private(set) var text: MarkdownRenderedText
    /// Display-only substitutions outside the raw caret line. Sorted by source
    /// range, matching the runs of `text.document`.
    private(set) var substitutions: [RenderedEditorSubstitution]
    /// Images the editor may draw, sorted by source range.
    private(set) var images: [RenderedEditorImage]

    init(source: String, renderer: MarkdownRenderer = MarkdownRenderer()) throws {
        self.text = try MarkdownRenderedText(source: source, renderer: renderer)
        self.substitutions = Self.makeSubstitutions(in: text.document)
        self.images = Self.makeImages(in: text.document)
    }

    var source: String { text.document.source }
    var sourceLength: Int { text.document.sourceLength }
    var displayLength: Int { text.document.displayLength }

    /// Applies one UTF-16 source edit and incrementally reuses unchanged
    /// blocks.
    @discardableResult
    mutating func apply(_ edit: SourceEdit) throws -> Set<BlockID> {
        let invalidated = try text.apply(edit)
        substitutions = Self.makeSubstitutions(in: text.document)
        images = Self.makeImages(in: text.document)
        return invalidated
    }

    /// The substitution covering `offset`, if any.
    func substitution(at offset: Int) -> RenderedEditorSubstitution? {
        var low = 0
        var high = substitutions.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let candidate = substitutions[middle]
            if offset < candidate.sourceRange.lowerBound {
                high = middle - 1
            } else if offset >= candidate.sourceRange.upperBound {
                low = middle + 1
            } else {
                return candidate
            }
        }
        return nil
    }

    /// All spans that intersect `range`, in source order.
    ///
    /// A span intersecting `activeLine` is marked `isRaw`, including runs that
    /// cross the line boundary. Runs are line-scoped for the Markdown renderer,
    /// so this keeps the whole caret line literal without splitting display
    /// substitutions.
    func spans(intersecting range: Range<Int>,
               activeLine: Range<Int>?) -> [RenderedEditorSpan] {
        guard range.lowerBound < range.upperBound else { return [] }
        let query = max(0, range.lowerBound)..<min(sourceLength, range.upperBound)
        guard query.lowerBound < query.upperBound else { return [] }

        var spans: [RenderedEditorSpan] = []
        for block in text.document.blocks {
            if block.sourceRange.upperBound <= query.lowerBound { continue }
            if block.sourceRange.lowerBound >= query.upperBound { break }
            for run in block.runs {
                guard run.sourceRange.overlaps(query) else { continue }
                let isRaw = activeLine.map { $0.overlaps(run.sourceRange) } ?? false
                let isHidden = run.displayLength == 0 && !isRaw
                let isSubstitution = !isRaw && !isHidden
                    && substitution(at: run.sourceRange.lowerBound) != nil
                spans.append(RenderedEditorSpan(
                    sourceRange: run.sourceRange,
                    isHidden: isHidden,
                    isRaw: isRaw,
                    displayText: run.displayText,
                    isSubstitution: isSubstitution,
                    role: run.role,
                    attributes: run.attributes))
            }
        }
        return spans
    }

    /// Every span in the document.
    func spans(activeLine: Range<Int>?) -> [RenderedEditorSpan] {
        spans(intersecting: 0..<max(1, sourceLength), activeLine: activeLine)
    }

    /// The source line containing `offset`, including its newline.
    ///
    /// At an offset after a trailing newline this returns the empty final line.
    func lineRange(containing offset: Int) -> Range<Int> {
        let text = source as NSString
        let location = max(0, min(offset, text.length))
        let range = text.lineRange(for: NSRange(location: location, length: 0))
        return range.location..<NSMaxRange(range)
    }

    // MARK: Caret movement

    /// Maps a source offset to the closest display offset.
    func displayOffset(forSource offset: Int,
                       affinity: TextAffinity = .trailing) -> Int? {
        text.document.map.displayOffset(for: offset, affinity: affinity)
    }

    /// Maps a display offset back to a source offset.
    func sourceOffset(forDisplay offset: Int,
                      affinity: TextAffinity = .leading) -> Int {
        text.document.map.sourceOffset(for: offset, affinity: affinity)
    }

    func isHiddenSourceOffset(_ offset: Int) -> Bool {
        text.document.map.isHiddenSourceOffset(offset)
    }

    /// Returns the next caret position in `direction` (−1 or +1).
    ///
    /// Inside `activeLine` the caret moves through literal source one UTF-16
    /// unit at a time. Outside it the caret moves through display positions,
    /// so collapsed markers are skipped and the caret never lands inside
    /// syntax that is not currently shown.
    func nextSourceOffset(from offset: Int,
                          direction: Int,
                          activeLine: Range<Int>?) -> Int {
        guard direction != 0 else { return clamp(offset) }
        let step = direction > 0 ? 1 : -1
        let current = clamp(offset)

        if let activeLine,
           current >= activeLine.lowerBound,
           current <= activeLine.upperBound {
            let candidate = current + step
            if candidate >= activeLine.lowerBound, candidate <= activeLine.upperBound {
                return candidate
            }
        }

        let affinity: TextAffinity = step > 0 ? .trailing : .leading
        guard let display = displayOffset(forSource: current, affinity: affinity) else {
            return current
        }
        let target = max(0, min(display + step, displayLength))
        return sourceOffset(forDisplay: target, affinity: affinity)
    }

    private func clamp(_ offset: Int) -> Int {
        max(0, min(offset, sourceLength))
    }

    // MARK: Substitutions

    private static func makeSubstitutions(
        in document: RenderedDocument
    ) -> [RenderedEditorSubstitution] {
        var result: [RenderedEditorSubstitution] = []
        let source = document.source as NSString
        for block in document.blocks {
            for run in block.runs
            where isDisplaySubstitution(run, in: source) {
                result.append(RenderedEditorSubstitution(
                    sourceRange: run.sourceRange,
                    displayText: run.displayText,
                    role: run.role))
            }
        }
        return result
    }

    // MARK: Images

    /// Substitutions preserve the source range but show different glyphs.
    ///
    /// A display string longer than its source range cannot be represented by
    /// one visible source slot per display unit, so it keeps the source
    /// spelling. Line breaks and other control characters are excluded because
    /// hiding or substituting them would change the document's line structure.
    private static func isDisplaySubstitution(
        _ run: RenderedRun,
        in source: NSString
    ) -> Bool {
        guard run.displayLength > 0,
              run.displayLength <= run.sourceRange.count,
              run.role != .lineBreak,
              run.role != .softBreak,
              !run.displayText.unicodeScalars.contains(where: { scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .lineSeparator, .paragraphSeparator, .format:
                      return true
                  default:
                      return false
                  }
              }) else { return false }
        let sourceText = source.substring(
            with: NSRange(location: run.sourceRange.lowerBound,
                          length: run.sourceRange.count))
        return sourceText != run.displayText
    }

    private static func makeImages(in document: RenderedDocument) -> [RenderedEditorImage] {
        let source = document.source as NSString
        var result: [RenderedEditorImage] = []
        var seen = Set<Range<Int>>()

        for block in document.blocks {
            for run in block.runs where run.attributes.isImage {
                guard let destination = run.attributes.linkDestination,
                      let sourceRange = imageSyntaxRange(
                        containing: run.sourceRange, in: source),
                      seen.insert(sourceRange).inserted else { continue }

                let syntax = source.substring(with: NSRange(
                    location: sourceRange.lowerBound, length: sourceRange.count))
                let line = source.lineRange(for: NSRange(
                    location: sourceRange.lowerBound, length: 0))
                let lineText = source.substring(with: line)
                let altText = run.role == .image ? "" : run.displayText

                result.append(RenderedEditorImage(
                    sourceRange: sourceRange,
                    destination: destination,
                    altText: altText,
                    isStandalone: lineText.trimmingCharacters(in: .whitespacesAndNewlines)
                        == syntax))
            }
        }
        return result.sorted { $0.sourceRange.lowerBound < $1.sourceRange.lowerBound }
    }

    /// The complete `![alt](destination)` range for an image run.
    ///
    /// The renderer reports the alt text (or the empty-alt placeholder) as the
    /// image run, with the brackets and destination in neighbouring hidden
    /// runs. Expanding from the run again keeps the projection untouched while
    /// still giving the host a range to draw over.
    private static func imageSyntaxRange(containing run: Range<Int>,
                                         in source: NSString) -> Range<Int>? {
        let length = source.length
        guard run.lowerBound <= length, run.upperBound <= length else { return nil }

        var lower = run.lowerBound
        if lower >= 2,
           source.substring(with: NSRange(location: lower - 2, length: 2)) == "![" {
            lower -= 2
        }
        guard lower + 1 < length,
              source.substring(with: NSRange(location: lower, length: 2)) == "![" else {
            return nil
        }

        // Find the closing bracket of the alt text. Starting at `lower + 2`
        // (rather than after the run) matters for empty alt text, where the
        // renderer's run can extend into the destination instead of covering
        // just the alt text.
        var index = lower + 2
        var bracketDepth = 0
        while index < length {
            let character = source.character(at: index)
            if character == 0x0A || character == 0x0D { return nil }
            if character == 0x5C {   // backslash escapes the next unit
                index += 2
                continue
            }
            if character == 0x5B {   // "["
                bracketDepth += 1
            } else if character == 0x5D {   // "]"
                if bracketDepth == 0 { break }
                bracketDepth -= 1
            }
            index += 1
        }
        guard index + 1 < length,
              source.character(at: index) == 0x5D,
              source.character(at: index + 1) == 0x28 else { return nil } // "("

        index += 2
        var depth = 1
        while index < length {
            let character = source.character(at: index)
            if character == 0x0A || character == 0x0D { return nil }
            if character == 0x5C {   // backslash escapes the next unit
                index += 2
                continue
            }
            if character == 0x28 { depth += 1 }
            if character == 0x29 {
                depth -= 1
                if depth == 0 { return lower..<(index + 1) }
            }
            index += 1
        }
        return nil
    }
}
