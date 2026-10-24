import Foundation

/// Accumulates the region of a text storage that has been edited but not yet
/// re-highlighted.
///
/// Highlighting is debounced, so several edits can happen before it runs. The
/// naive approach (remember only the *last* edit's range) loses earlier edits,
/// and a stale range can also point past the end of a document that has since
/// shrunk. `DirtyRange` keeps one range that covers every pending edit and
/// shifts it as later edits insert or delete text before it.
struct DirtyRange: Equatable {
    /// The pending region in current-document coordinates, if any.
    private(set) var range: NSRange?

    /// Records an edit as reported by `NSTextStorageDelegate`.
    ///
    /// - Parameters:
    ///   - edited: The edited range **after** the edit.
    ///   - delta: Change in document length caused by the edit.
    mutating func record(edited: NSRange, delta: Int) {
        guard let existing = range else {
            range = edited
            return
        }
        // End of the replaced text in *pre-edit* coordinates.
        let oldEditedEnd = NSMaxRange(edited) - delta

        // Map a pre-edit position to its post-edit position.
        func shift(_ position: Int) -> Int {
            if position >= oldEditedEnd { return position + delta }   // after the edit
            if position > edited.location { return edited.location }  // swallowed by it
            return position                                           // before the edit
        }

        let lower = shift(existing.location)
        let upper = max(shift(NSMaxRange(existing)), lower)
        range = NSUnionRange(NSRange(location: lower, length: upper - lower), edited)
    }

    /// Returns the pending region clamped to a document of `length` UTF-16
    /// units, and clears it. Returns `nil` when there is nothing to do.
    ///
    /// A zero-length result is meaningful (a pure deletion still requires its
    /// line to be re-highlighted), so it is returned rather than dropped.
    mutating func take(clampedTo length: Int) -> NSRange? {
        defer { range = nil }
        guard let pending = range, length > 0 else { return nil }
        let start = min(pending.location, length)
        let end = min(max(NSMaxRange(pending), start), length)
        return NSRange(location: start, length: end - start)
    }
}
