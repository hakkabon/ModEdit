import Foundation

/// A stable identity for a rendered block.
///
/// The identity is derived from the block kind and its exact source text, not
/// from its position. Moving an unchanged block therefore preserves its ID,
/// which is what lets the editor reuse its rendered runs after an unrelated
/// edit. Identical blocks are disambiguated by their occurrence ordinal.
public struct BlockID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let kind: RenderedBlockKind
    public let contentHash: UInt64
    public let occurrence: Int

    public init(kind: RenderedBlockKind, contentHash: UInt64, occurrence: Int) {
        self.kind = kind
        self.contentHash = contentHash
        self.occurrence = occurrence
    }

    public static func < (lhs: BlockID, rhs: BlockID) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.contentHash != rhs.contentHash {
            return lhs.contentHash < rhs.contentHash
        }
        return lhs.occurrence < rhs.occurrence
    }

    public var description: String {
        "\(kind.rawValue)-\(String(contentHash, radix: 16))-\(occurrence)"
    }
}

/// The structural role of a rendered block.
public enum RenderedBlockKind: String, Hashable, Sendable, CaseIterable {
    case heading
    case paragraph
    case list
    case blockQuote
    case codeBlock
    case table
    case thematicBreak
    case htmlBlock
    case blank
    case other
}

/// The role of a run inside a block.
///
/// Hidden syntax has an empty display string and a non-empty source range.
/// Visible runs may still have different source and display lengths (for
/// example, an HTML entity or a thematic-break replacement).
public enum RenderedRunRole: String, Hashable, Sendable {
    case text
    case hiddenSyntax
    case softBreak
    case lineBreak
    case code
    case listMarker
    case tableSeparator
    case thematicBreak
    case image
    case html
}

/// A list marker's semantic form, independent of its source spelling.
public enum ListMarker: Hashable, Sendable {
    case bullet
    case ordered(Int)
    case task(checked: Bool)
}

/// Platform-neutral presentation attributes for a run.
///
/// This deliberately contains no font, colour or layout types. The editor host
/// decides how to turn these semantics into `NSAttributedString` attributes.
public struct RenderedAttributes: Hashable, Sendable {
    public var isStrong: Bool
    public var isEmphasis: Bool
    public var isStrikethrough: Bool
    public var isCode: Bool
    public var isLink: Bool
    public var isImage: Bool
    public var isHTML: Bool
    public var isBlockQuote: Bool
    public var headingLevel: Int?
    public var linkDestination: String?
    public var codeLanguage: String?
    public var listMarker: ListMarker?

    public init(isStrong: Bool = false,
                isEmphasis: Bool = false,
                isStrikethrough: Bool = false,
                isCode: Bool = false,
                isLink: Bool = false,
                isImage: Bool = false,
                isHTML: Bool = false,
                isBlockQuote: Bool = false,
                headingLevel: Int? = nil,
                linkDestination: String? = nil,
                codeLanguage: String? = nil,
                listMarker: ListMarker? = nil) {
        self.isStrong = isStrong
        self.isEmphasis = isEmphasis
        self.isStrikethrough = isStrikethrough
        self.isCode = isCode
        self.isLink = isLink
        self.isImage = isImage
        self.isHTML = isHTML
        self.isBlockQuote = isBlockQuote
        self.headingLevel = headingLevel
        self.linkDestination = linkDestination
        self.codeLanguage = codeLanguage
        self.listMarker = listMarker
    }
}

/// One run of a rendered block.
///
/// `sourceRange` is always non-empty and in UTF-16 units. The runs of a block
/// are sorted, contiguous and tile the block's source range exactly. Hidden
/// markup is represented by a run with `displayText == ""`, never by deleting
/// its source range.
public struct RenderedRun: Hashable, Sendable {
    public let sourceRange: Range<Int>
    public let displayText: String
    public let role: RenderedRunRole
    public let attributes: RenderedAttributes

    public init(sourceRange: Range<Int>,
                displayText: String,
                role: RenderedRunRole = .text,
                attributes: RenderedAttributes = RenderedAttributes()) {
        self.sourceRange = sourceRange
        self.displayText = displayText
        self.role = role
        self.attributes = attributes
    }

    public var displayLength: Int { displayText.utf16.count }
}

/// A rendered block: a source range plus runs that project it into display text.
public struct RenderedBlock: Hashable, Sendable {
    public let id: BlockID
    public let kind: RenderedBlockKind
    public let sourceRange: Range<Int>
    public let runs: [RenderedRun]

    public init(id: BlockID,
                kind: RenderedBlockKind,
                sourceRange: Range<Int>,
                runs: [RenderedRun]) {
        self.id = id
        self.kind = kind
        self.sourceRange = sourceRange
        self.runs = runs
    }

    public var displayText: String {
        runs.map(\.displayText).joined()
    }

    public var displayLength: Int {
        runs.reduce(0) { $0 + $1.displayLength }
    }
}

/// A complete projected document.
///
/// Blocks partition the source exactly, including blank lines and invisible
/// constructs. Runs partition each block. The initializer validates both
/// invariants before building the source-display map.
public struct RenderedDocument: Hashable, Sendable {
    public let source: String
    public let blocks: [RenderedBlock]
    public let map: SourceDisplayMap
    public let displayText: String

    public init(source: String, blocks: [RenderedBlock]) throws {
        let sourceLength = source.utf16.count
        try Self.validate(sourceLength: sourceLength, blocks: blocks)
        self.source = source
        self.blocks = blocks
        self.map = SourceDisplayMap(blocks: blocks)
        self.displayText = blocks.map(\.displayText).joined()
    }

    public init<R: RenderedTextRenderer>(source: String, renderer: R) throws {
        let tree = renderer.parse(source)
        let blocks = renderer.blocks(in: tree).map { renderer.render($0, in: tree) }
        try self.init(source: source, blocks: blocks)
    }

    public var sourceLength: Int { source.utf16.count }
    public var displayLength: Int { map.displayLength }

    /// Returns the block whose source range contains `offset`.
    ///
    /// At a block boundary the later block is returned. This mirrors the
    /// trailing-affinity convention used by the display map.
    public func block(containingSourceOffset offset: Int) -> RenderedBlock? {
        guard offset >= 0, offset <= sourceLength else { return nil }
        return blocks.first {
            $0.sourceRange.lowerBound <= offset && offset < $0.sourceRange.upperBound
        } ?? blocks.last(where: { $0.sourceRange.upperBound == offset })
    }

    /// The source text covered by a UTF-16 range.
    public func sourceText(in range: Range<Int>) -> String {
        let text = source as NSString
        let lower = max(0, min(range.lowerBound, text.length))
        let upper = max(lower, min(range.upperBound, text.length))
        return text.substring(with: NSRange(location: lower, length: upper - lower))
    }

    /// Block IDs that an edit can affect.
    ///
    /// An insertion at a block boundary touches both neighbours, because the
    /// edit can merge, split or change either block. A replacement touches
    /// every block it overlaps.
    public func invalidatedBlockIDs(for edit: SourceEdit) -> Set<BlockID> {
        var result: Set<BlockID> = []
        if edit.range.isEmpty {
            let offset = edit.range.lowerBound
            for block in blocks
            where block.sourceRange.lowerBound <= offset
                && offset <= block.sourceRange.upperBound {
                result.insert(block.id)
            }
        } else {
            for block in blocks where block.sourceRange.overlaps(edit.range) {
                result.insert(block.id)
            }
        }
        return result
    }

    // MARK: Validation

    private static func validate(sourceLength: Int, blocks: [RenderedBlock]) throws {
        var blockCursor = 0
        var ids: Set<BlockID> = []

        for block in blocks {
            let insertion = ids.insert(block.id)
            guard insertion.inserted else {
                throw RenderedDocumentError.duplicateBlockID(block.id)
            }
            guard block.sourceRange.lowerBound == blockCursor else {
                if block.sourceRange.lowerBound < blockCursor {
                    throw RenderedDocumentError.overlappingBlock(block.id)
                }
                throw RenderedDocumentError.blockGap(
                    expected: blockCursor,
                    actual: block.sourceRange.lowerBound)
            }
            guard block.sourceRange.lowerBound >= 0,
                  block.sourceRange.upperBound <= sourceLength,
                  !block.sourceRange.isEmpty else {
                throw RenderedDocumentError.blockOutsideSource(block.id)
            }

            var runCursor = block.sourceRange.lowerBound
            for run in block.runs {
                guard !run.sourceRange.isEmpty else {
                    throw RenderedDocumentError.emptyRun(block.id)
                }
                guard run.sourceRange.lowerBound == runCursor else {
                    if run.sourceRange.lowerBound < runCursor {
                        throw RenderedDocumentError.overlappingRun(block.id)
                    }
                    throw RenderedDocumentError.runGap(
                        block: block.id,
                        expected: runCursor,
                        actual: run.sourceRange.lowerBound)
                }
                guard run.sourceRange.upperBound <= block.sourceRange.upperBound else {
                    throw RenderedDocumentError.runOutsideBlock(block.id)
                }
                guard !run.displayText.isEmpty || run.role == .hiddenSyntax else {
                    throw RenderedDocumentError.emptyVisibleRun(block.id)
                }
                runCursor = run.sourceRange.upperBound
            }
            guard runCursor == block.sourceRange.upperBound else {
                throw RenderedDocumentError.runGap(
                    block: block.id,
                    expected: runCursor,
                    actual: block.sourceRange.upperBound)
            }
            blockCursor = block.sourceRange.upperBound
        }

        guard blockCursor == sourceLength else {
            throw RenderedDocumentError.blockGap(
                expected: blockCursor,
                actual: sourceLength)
        }
    }
}

public enum RenderedDocumentError: Error, Hashable, Sendable, CustomStringConvertible {
    case duplicateBlockID(BlockID)
    case overlappingBlock(BlockID)
    case blockGap(expected: Int, actual: Int)
    case blockOutsideSource(BlockID)
    case emptyRun(BlockID)
    case overlappingRun(BlockID)
    case runGap(block: BlockID, expected: Int, actual: Int)
    case runOutsideBlock(BlockID)
    case emptyVisibleRun(BlockID)
    case invalidEditRange

    public var description: String {
        switch self {
        case .duplicateBlockID(let id):
            return "Duplicate block ID \(id)."
        case .overlappingBlock(let id):
            return "Block \(id) overlaps the previous block."
        case .blockGap(let expected, let actual):
            return "Blocks do not partition the source (expected \(expected), found \(actual))."
        case .blockOutsideSource(let id):
            return "Block \(id) has an empty or out-of-bounds source range."
        case .emptyRun(let id):
            return "Block \(id) contains an empty run."
        case .overlappingRun(let id):
            return "Block \(id) contains overlapping runs."
        case .runGap(let block, let expected, let actual):
            return "Runs in \(block) do not tile the block (expected \(expected), found \(actual))."
        case .runOutsideBlock(let id):
            return "A run in block \(id) extends outside the block."
        case .emptyVisibleRun(let id):
            return "Block \(id) contains an empty visible run."
        case .invalidEditRange:
            return "The source edit range is outside the document."
        }
    }
}

/// An edit to a rendered document's source.
///
/// `range` is in UTF-16 units in the document *before* the edit.
public struct SourceEdit: Hashable, Sendable {
    public let range: Range<Int>
    public let replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    public var replacementLength: Int { replacement.utf16.count }
}

/// FNV-1a over the UTF-8 bytes of a string.
///
/// A tiny deterministic hash is enough for block identity; source text is
/// compared as well when blocks are reused.
enum StableHash {
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
