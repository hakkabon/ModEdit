import Foundation

/// A renderer that parses a source document and projects individual blocks.
///
/// Parsing is separate from rendering so an incremental host can reuse the
/// tree, compare block descriptors, and re-render only blocks whose source
/// content changed.
public protocol RenderedTextRenderer {
    associatedtype Tree

    /// Parses the complete source into a renderer-specific tree.
    func parse(_ source: String) -> Tree

    /// Describes every block that partitions the source, in source order.
    ///
    /// The descriptors must cover the source exactly, including blank lines and
    /// invisible constructs. The renderer uses gap descriptors for regions the
    /// language parser does not expose as a block.
    func blocks(in tree: Tree) -> [RenderedBlockDescriptor]

    /// Renders one descriptor into runs.
    func render(_ descriptor: RenderedBlockDescriptor, in tree: Tree) -> RenderedBlock
}

/// A renderer-independent block descriptor.
///
/// `id` is stable while the block's kind and exact source text are unchanged.
/// `payload` is opaque to callers and identifies the renderer's internal node.
public struct RenderedBlockDescriptor: Hashable, Sendable {
    public let id: BlockID
    public let kind: RenderedBlockKind
    public let sourceRange: Range<Int>
    public let contentHash: UInt64
    public let occurrence: Int
    public let payload: Int

    public init(id: BlockID,
                kind: RenderedBlockKind,
                sourceRange: Range<Int>,
                contentHash: UInt64,
                occurrence: Int,
                payload: Int) {
        self.id = id
        self.kind = kind
        self.sourceRange = sourceRange
        self.contentHash = contentHash
        self.occurrence = occurrence
        self.payload = payload
    }
}
