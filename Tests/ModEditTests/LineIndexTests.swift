import Testing
import Foundation
@testable import ModEditCore

@Suite("LineIndex")
struct LineIndexTests {

    @Test func lineStartsRecogniseCRLFAsOneBreak() {
        let index = LineIndex(text: "a\r\nb\rc\nd")
        #expect(index.starts == [0, 3, 5, 7])
        #expect(index.isLineStart(at: 3))
        #expect(!index.isLineStart(at: 2))
        #expect(index.lineCount == 4)
    }

    @Test func crlfSplitAcrossRebuildChunksIsOneBreak() {
        // The rebuild reads 64k UTF-16 units at a time. Put the CR in one chunk
        // and the LF in the next.
        let prefix = String(repeating: "a", count: 65_535)
        let index = LineIndex(text: prefix + "\r\nb\n")

        #expect(index.starts == [0, 65_537, 65_539])
    }

    @Test func incrementalUpdatesMatchFullRebuildForSingleEdits() {
        let samples = [
            "", "a", "\n", "\r", "\r\n", "a\n", "a\r", "a\r\n",
            "a\nb", "a\r\nb", "a\rb", "one\ntwo\nthree",
            "a\r\n\r\nb\n", "👩🏽‍💻\n日本語\n",
        ]
        let replacements = ["", "x", "\n", "\r", "\r\n", "x\ny", "\n\n", "👩🏽‍💻", "z\r\n"]

        for original in samples {
            let source = original as NSString
            for location in 0...source.length {
                for length in 0...(source.length - location) {
                    for replacement in replacements {
                        let range = NSRange(location: location, length: length)
                        let edited = source.replacingCharacters(in: range, with: replacement)

                        var index = LineIndex(text: original)
                        index.apply(editIn: range,
                                    delta: (replacement as NSString).length - length,
                                    in: edited as NSString)

                        let expected = LineIndex(text: edited)
                        #expect(
                            index.starts == expected.starts,
                            "edit \(range) -> \(replacement.debugDescription) in \(original.debugDescription): got \(index.starts), expected \(expected.starts)")
                    }
                }
            }
        }
    }

    @Test func randomizedIncrementalEditsMatchFullRebuild() {
        var text = "alpha\r\nbeta\rgamma\n\ndelta\n"
        var index = LineIndex(text: text)
        var rng = SeededGenerator(seed: 0x4D6F6445_64697421)
        let replacements = ["", "x", "\n", "\r", "\r\n", "abc", "x\ny", "\r\r\n", ""]

        for step in 0..<500 {
            let source = text as NSString
            let location = Int.random(in: 0...source.length, using: &rng)
            let maxLength = min(8, source.length - location)
            let length = Int.random(in: 0...maxLength, using: &rng)
            let replacement = replacements.randomElement(using: &rng)!
            let range = NSRange(location: location, length: length)

            text = source.replacingCharacters(in: range, with: replacement)
            index.apply(editIn: range,
                        delta: (replacement as NSString).length - length,
                        in: text as NSString)

            let expected = LineIndex(text: text)
            #expect(index.starts == expected.starts,
                    "step \(step): edit \(range) -> \(replacement.debugDescription) in \(text.debugDescription)")
            if index.starts != expected.starts { return }
        }
    }

    @Test func repeatedIncrementalEditsStayCorrect() {
        var text = "one\ntwo\r\nthree\rfour"
        var index = LineIndex(text: text)
        let edits: [(NSRange, String)] = [
            (NSRange(location: 2, length: 1), ""),          // same line count, shorter
            (NSRange(location: 0, length: 0), "abcde"),     // same line count, longer
            (NSRange(location: 7, length: 1), "\n"),        // replace with newline
            (NSRange(location: 1, length: 1), "\r\n"),      // create CRLF
            (NSRange(location: 4, length: 2), ""),          // delete across CRLF
            (NSRange(location: 0, length: 0), "\n"),        // new first line
            (NSRange(location: (text as NSString).length, length: 0), "\n"), // trailing empty line
        ]

        for (range, replacement) in edits {
            let source = text as NSString
            let safeRange = NSRange(location: min(range.location, source.length),
                                    length: min(range.length, source.length - min(range.location, source.length)))
            text = source.replacingCharacters(in: safeRange, with: replacement)
            index.apply(editIn: safeRange,
                        delta: (replacement as NSString).length - safeRange.length,
                        in: text as NSString)
            #expect(index.starts == LineIndex(text: text).starts,
                    "after editing \(safeRange) with \(replacement.debugDescription), text is \(text.debugDescription)")
        }
    }
}

/// Deterministic generator so a failing edit sequence can be reproduced.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
