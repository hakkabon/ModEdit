import Testing
import Foundation
@testable import ModEditCore

@Suite("DirtyRange")
struct DirtyRangeTests {

    @Test func firstEditIsRecordedAsIs() {
        var dirty = DirtyRange()
        dirty.record(edited: NSRange(location: 10, length: 1), delta: 1)
        #expect(dirty.range == NSRange(location: 10, length: 1))
    }

    @Test func laterEditBeforeShiftsEarlierRange() {
        var dirty = DirtyRange()
        dirty.record(edited: NSRange(location: 10, length: 1), delta: 1)
        // Two characters inserted at the start push the earlier edit to 12...13.
        dirty.record(edited: NSRange(location: 0, length: 2), delta: 2)
        #expect(dirty.range == NSRange(location: 0, length: 13))
    }

    @Test func deletionShiftsEarlierRangeLeft() {
        var dirty = DirtyRange()
        dirty.record(edited: NSRange(location: 5, length: 0), delta: -3)
        dirty.record(edited: NSRange(location: 2, length: 0), delta: -1)
        #expect(dirty.range == NSRange(location: 2, length: 2))
    }

    @Test func takeClampsAndClears() {
        var dirty = DirtyRange()
        dirty.record(edited: NSRange(location: 5, length: 100), delta: 100)
        #expect(dirty.take(clampedTo: 20) == NSRange(location: 5, length: 15))
        #expect(dirty.range == nil)
        #expect(dirty.take(clampedTo: 20) == nil)
    }

    @Test func emptyDocumentHasNothingToHighlight() {
        var dirty = DirtyRange()
        dirty.record(edited: NSRange(location: 0, length: 0), delta: -4)
        #expect(dirty.take(clampedTo: 0) == nil)
    }
}
