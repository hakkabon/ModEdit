import Foundation

/// An immutable, versioned view of a document. Parsers echo `version` in their
/// results so clients can discard work superseded by a newer edit.
public struct SourceSnapshot: Sendable, Equatable {
    public let version: UInt64
    public let text: String
    public let edit: SourceEdit?

    public init(version: UInt64, text: String, edit: SourceEdit? = nil) {
        self.version = version
        self.text = text
        self.edit = edit
    }
}

/// One replacement expressed in UTF-16 offsets, matching TextKit and LSP.
public struct SourceEdit: Sendable, Equatable {
    public let replacedRange: SourceRange
    public let replacementLength: Int

    public init(replacedRange: SourceRange, replacementLength: Int) {
        self.replacedRange = replacedRange
        self.replacementLength = replacementLength
    }
}

public struct SourceRange: Sendable, Equatable, Hashable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var end: Int { location + length }
    public static let zero = SourceRange(location: 0, length: 0)
}

public struct SourceLocation: Sendable, Equatable {
    public let offset: Int
    public let line: Int
    public let column: Int

    public init(offset: Int, line: Int, column: Int) {
        self.offset = offset
        self.line = line
        self.column = column
    }
}
