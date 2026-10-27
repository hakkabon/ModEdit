/// Supplies logical line information to views without letting each view keep a
/// second line index of its own.
@MainActor
protocol LineNumberSource: AnyObject {
    /// Number of logical lines, at least one.
    var lineCount: Int { get }

    /// One-based line number for a UTF-16 offset.
    func lineNumber(at location: Int) -> Int

    /// Whether `location` is the start of a logical line.
    func isLineStart(at location: Int) -> Bool
}
