import Foundation

/// A Markdown document that supports incremental projection updates.
///
/// Applying an edit reparses the Markdown tree, then reuses every block whose
/// kind and exact source text are unchanged. Reused blocks keep their ID and
/// shift their runs by the edit delta; only genuinely new or changed blocks are
/// rendered again.
public struct MarkdownRenderedText: Sendable {
    public private(set) var document: RenderedDocument
    public private(set) var lastInvalidatedBlockIDs: Set<BlockID>
    public private(set) var lastRenderedBlockIDs: Set<BlockID>
    public private(set) var lastReusedBlockIDs: Set<BlockID>
    public let renderer: MarkdownRenderer

    public init(source: String,
                renderer: MarkdownRenderer = MarkdownRenderer()) throws {
        self.renderer = renderer
        self.document = try renderer.render(source)
        self.lastInvalidatedBlockIDs = []
        self.lastRenderedBlockIDs = []
        self.lastReusedBlockIDs = []
    }

    /// Applies an edit and returns the old block IDs that the edit could affect.
    @discardableResult
    public mutating func apply(_ edit: SourceEdit) throws -> Set<BlockID> {
        let oldSource = document.source as NSString
        guard edit.range.lowerBound >= 0,
              edit.range.lowerBound <= edit.range.upperBound,
              edit.range.upperBound <= oldSource.length else {
            throw RenderedDocumentError.invalidEditRange
        }

        let invalidated = document.invalidatedBlockIDs(for: edit)
        let newSource = oldSource.replacingCharacters(
            in: NSRange(location: edit.range.lowerBound, length: edit.range.count),
            with: edit.replacement)
        let tree = renderer.parse(newSource)
        let descriptors = renderer.blocks(in: tree)
        let newText = newSource as NSString

        var oldByID: [BlockID: RenderedBlock] = [:]
        for block in document.blocks {
            oldByID[block.id] = block
        }

        var blocks: [RenderedBlock] = []
        blocks.reserveCapacity(descriptors.count)
        var rendered: Set<BlockID> = []
        var reused: Set<BlockID> = []

        for descriptor in descriptors {
            if let old = oldByID[descriptor.id],
               old.kind == descriptor.kind,
               oldSource.substring(with: NSRange(
                    location: old.sourceRange.lowerBound,
                    length: old.sourceRange.count))
                == newText.substring(with: NSRange(
                    location: descriptor.sourceRange.lowerBound,
                    length: descriptor.sourceRange.count)) {
                let delta = descriptor.sourceRange.lowerBound - old.sourceRange.lowerBound
                let shiftedRuns = old.runs.map { run in
                    RenderedRun(
                        sourceRange: (run.sourceRange.lowerBound + delta)
                            ..< (run.sourceRange.upperBound + delta),
                        displayText: run.displayText,
                        role: run.role,
                        attributes: run.attributes)
                }
                blocks.append(RenderedBlock(
                    id: old.id,
                    kind: old.kind,
                    sourceRange: descriptor.sourceRange,
                    runs: shiftedRuns))
                reused.insert(old.id)
            } else {
                blocks.append(renderer.render(descriptor, in: tree))
                rendered.insert(descriptor.id)
            }
        }

        document = try RenderedDocument(source: newSource, blocks: blocks)
        lastInvalidatedBlockIDs = invalidated
        lastRenderedBlockIDs = rendered
        lastReusedBlockIDs = reused
        return invalidated
    }

    /// Convenience for a replacement expressed as a UTF-16 range.
    @discardableResult
    public mutating func replaceText(in range: Range<Int>,
                                     with replacement: String) throws -> Set<BlockID> {
        try apply(SourceEdit(range: range, replacement: replacement))
    }
}
