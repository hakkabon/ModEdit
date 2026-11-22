import Foundation

/// Which side of a source or display boundary a position belongs to.
///
/// Hidden markup has no display width, so a display boundary can correspond to
/// several source positions. `leading` resolves to the position before the
/// hidden syntax at that boundary; `trailing` resolves to the position after it.
public enum TextAffinity: String, Hashable, Sendable, CaseIterable {
    case leading
    case trailing
}

/// A monotonic, affinity-aware map between UTF-16 source offsets and UTF-16
/// display offsets.
///
/// The map is built from rendered runs. Visible text with equal source and
/// display lengths maps one-to-one. Hidden syntax maps a non-empty source range
/// to a zero-width display range. Substitutions (entities, escapes, list
/// markers, thematic breaks) map proportionally, monotonically.
public struct SourceDisplayMap: Hashable, Sendable {
    private struct Entry: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case identity
            case hidden
            case substitution
        }

        let sourceRange: Range<Int>
        let displayRange: Range<Int>
        let kind: Kind
    }

    private let entries: [Entry]

    public let sourceLength: Int
    public let displayLength: Int

    init(blocks: [RenderedBlock]) {
        var entries: [Entry] = []
        var displayCursor = 0
        var sourceCursor = 0

        for block in blocks {
            for run in block.runs {
                let sourceLength = run.sourceRange.count
                let displayLength = run.displayLength
                let kind: Entry.Kind
                if displayLength == 0 {
                    kind = .hidden
                } else if displayLength == sourceLength {
                    kind = .identity
                } else {
                    kind = .substitution
                }
                entries.append(Entry(
                    sourceRange: run.sourceRange,
                    displayRange: displayCursor..<(displayCursor + displayLength),
                    kind: kind))
                sourceCursor = run.sourceRange.upperBound
                displayCursor += displayLength
            }
        }

        self.entries = entries
        self.sourceLength = sourceCursor
        self.displayLength = displayCursor
    }

    // MARK: Source -> display

    /// Maps a source offset to a display offset.
    ///
    /// Returns `nil` only when `sourceOffset` is outside `0...sourceLength`.
    /// At a boundary, `leading` stops before hidden syntax and `trailing`
    /// crosses it.
    public func displayOffset(for sourceOffset: Int,
                              affinity: TextAffinity = .trailing) -> Int? {
        guard sourceOffset >= 0, sourceOffset <= sourceLength else { return nil }
        guard !entries.isEmpty else { return 0 }
        if sourceOffset == sourceLength {
            return displayLength
        }

        let index = lastEntryStartingAtOrBefore(sourceOffset)
        guard index >= 0 else { return 0 }
        let entry = entries[index]

        if sourceOffset == entry.sourceRange.lowerBound {
            if index == 0 { return entry.displayRange.lowerBound }
            switch affinity {
            case .leading:
                return entries[index - 1].displayRange.upperBound
            case .trailing:
                // Cross any zero-width hidden run that starts here. If this
                // entry is visible, its start is already after that markup.
                return entry.kind == .hidden
                    ? entry.displayRange.upperBound
                    : entry.displayRange.lowerBound
            }
        }

        let relative = sourceOffset - entry.sourceRange.lowerBound
        switch entry.kind {
        case .identity:
            return entry.displayRange.lowerBound + relative
        case .hidden:
            return affinity == .leading
                ? entry.displayRange.lowerBound
                : entry.displayRange.upperBound
        case .substitution:
            let sourceCount = entry.sourceRange.count
            let displayCount = entry.displayRange.count
            let mapped: Int
            switch affinity {
            case .leading:
                mapped = (relative * displayCount) / sourceCount
            case .trailing:
                mapped = ((relative * displayCount) + sourceCount - 1) / sourceCount
            }
            return entry.displayRange.lowerBound + min(displayCount, mapped)
        }
    }

    // MARK: Display -> source

    /// Maps a display offset to a source offset.
    ///
    /// The result is always in `0...sourceLength`; out-of-range inputs clamp.
    /// At a display boundary, `leading` stops before hidden syntax and
    /// `trailing` crosses it.
    public func sourceOffset(for displayOffset: Int,
                             affinity: TextAffinity = .leading) -> Int {
        let displayOffset = max(0, min(displayOffset, displayLength))
        guard !entries.isEmpty else { return 0 }

        if displayOffset == displayLength {
            // A trailing run of zero-width entries is still a boundary group.
            // Leading keeps the caret in front of it; trailing moves past it.
            var zeroStart = entries.count
            while zeroStart > 0 {
                let previous = entries[zeroStart - 1]
                guard previous.displayRange.isEmpty,
                      previous.displayRange.lowerBound == displayOffset else { break }
                zeroStart -= 1
            }
            if zeroStart < entries.count, affinity == .leading {
                return entries[zeroStart].sourceRange.lowerBound
            }
            return sourceLength
        }

        // First entry whose display end is greater than the requested offset.
        // If it starts strictly before the offset, the offset is inside it.
        let strictIndex = firstEntryEndingAfter(displayOffset)
        if strictIndex < entries.count {
            let entry = entries[strictIndex]
            if entry.displayRange.lowerBound < displayOffset {
                let relative = displayOffset - entry.displayRange.lowerBound
                switch entry.kind {
                case .identity:
                    return entry.sourceRange.lowerBound + relative
                case .hidden:
                    return affinity == .leading
                        ? entry.sourceRange.lowerBound
                        : entry.sourceRange.upperBound
                case .substitution:
                    let sourceCount = entry.sourceRange.count
                    let displayCount = entry.displayRange.count
                    // Invert the same proportional function used by
                    // `displayOffset(for:)`, selecting the first source offset
                    // (leading) or the last one (trailing) that projects here.
                    let mapped: Int
                    switch affinity {
                    case .leading:
                        mapped = (relative * sourceCount + displayCount - 1) / displayCount
                    case .trailing:
                        mapped = (relative * sourceCount) / displayCount
                    }
                    return entry.sourceRange.lowerBound + max(0, min(sourceCount, mapped))
                }
            }
        }

        // The offset is a boundary. Zero-width entries at this boundary form a
        // group; leading selects its start, trailing its end. The group sits
        // after the last non-zero entry ending here and before the first
        // non-zero entry starting here.
        var zeroStart = strictIndex
        while zeroStart > 0 {
            let previous = entries[zeroStart - 1]
            guard previous.displayRange.isEmpty,
                  previous.displayRange.lowerBound == displayOffset else { break }
            zeroStart -= 1
        }
        let zeroEnd = strictIndex
        let beforeIndex = zeroStart - 1

        if zeroStart < zeroEnd {
            let zeroEntries = entries[zeroStart..<zeroEnd]
            switch affinity {
            case .leading:
                return zeroEntries.first?.sourceRange.lowerBound ?? 0
            case .trailing:
                return zeroEntries.last?.sourceRange.upperBound ?? sourceLength
            }
        }

        switch affinity {
        case .leading:
            if beforeIndex >= 0 { return entries[beforeIndex].sourceRange.upperBound }
            if strictIndex < entries.count {
                return entries[strictIndex].sourceRange.lowerBound
            }
            return 0
        case .trailing:
            if strictIndex < entries.count {
                return entries[strictIndex].sourceRange.lowerBound
            }
            if beforeIndex >= 0 { return entries[beforeIndex].sourceRange.upperBound }
            return sourceLength
        }
    }

    // MARK: Ranges

    /// Maps a source range to the display range that covers its visible text.
    public func displayRange(forSource range: Range<Int>,
                             affinity: TextAffinity = .trailing) -> Range<Int>? {
        guard range.lowerBound >= 0,
              range.upperBound <= sourceLength,
              range.lowerBound <= range.upperBound else { return nil }
        guard let lower = displayOffset(for: range.lowerBound, affinity: affinity),
              let upper = displayOffset(for: range.upperBound, affinity: affinity),
              lower <= upper else { return nil }
        return lower..<upper
    }

    /// Maps a display range to the source range that produced it.
    public func sourceRange(forDisplay range: Range<Int>,
                            affinity: TextAffinity = .leading) -> Range<Int>? {
        guard range.lowerBound >= 0,
              range.upperBound <= displayLength,
              range.lowerBound <= range.upperBound else { return nil }
        let lower = sourceOffset(for: range.lowerBound, affinity: affinity)
        let upper = sourceOffset(for: range.upperBound, affinity: affinity)
        guard lower <= upper else { return nil }
        return lower..<upper
    }

    /// Whether the source offset lies inside hidden syntax.
    public func isHiddenSourceOffset(_ offset: Int) -> Bool {
        guard offset >= 0, offset < sourceLength else { return false }
        let index = lastEntryStartingAtOrBefore(offset)
        guard index >= 0 else { return false }
        return entries[index].kind == .hidden
    }

    // MARK: Binary search

    private func lastEntryStartingAtOrBefore(_ offset: Int) -> Int {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if entries[middle].sourceRange.lowerBound <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower - 1
    }

    private func firstEntryEndingAfter(_ offset: Int) -> Int {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if entries[middle].displayRange.upperBound > offset {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }
}
