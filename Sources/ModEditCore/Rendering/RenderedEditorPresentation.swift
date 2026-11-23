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
    let role: RenderedRunRole
    let attributes: RenderedAttributes

    var displayLength: Int { isHidden ? 0 : sourceRange.count }
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

    init(source: String, renderer: MarkdownRenderer = MarkdownRenderer()) throws {
        self.text = try MarkdownRenderedText(source: source, renderer: renderer)
    }

    var source: String { text.document.source }
    var sourceLength: Int { text.document.sourceLength }
    var displayLength: Int { text.document.displayLength }

    /// Applies one UTF-16 source edit and incrementally reuses unchanged
    /// blocks.
    @discardableResult
    mutating func apply(_ edit: SourceEdit) throws -> Set<BlockID> {
        try text.apply(edit)
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
                spans.append(RenderedEditorSpan(
                    sourceRange: run.sourceRange,
                    isHidden: run.displayLength == 0 && !isRaw,
                    isRaw: isRaw,
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
}
