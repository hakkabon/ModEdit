import AppKit
import Foundation
import Testing
@testable import ModEditCore

/// Large-file benchmark, disabled during normal test runs.
///
/// Run it in release mode so the numbers mean something:
///
///     MODEDIT_BENCHMARK=1 swift test -c release --filter LargeFileBenchmark
///
/// It exercises the paths that must not copy the whole document on every
/// keystroke: loading, incremental edits, line lookup, snapshot/encode and one
/// debounced Markdown highlight pass.
@Suite("Large-file benchmark",
       .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MODEDIT_BENCHMARK"] == "1"))
@MainActor
struct LargeFileBenchmarkTests {

    @Test(arguments: [10, 50])
    func benchmark(megabytes: Int) throws {
        let text = Self.makeDocument(megabytes: megabytes)
        let byteCount = text.lengthOfBytes(using: .utf8)
        let decoded = TextIO.Decoded(text: text, encoding: .utf8, byteOrderMark: nil)
        let document = EditorDocument()
        let format = MarkdownFormat()

        let load = measure {
            document.load(decoded, format: format)
        }
        report(size: megabytes, operation: "load+line-index", seconds: load, detail: "\(document.numberOfLines) lines")

        let length = document.textLength
        let middle = length / 2
        let nearEnd = length - max(1, length / 100)

        let lookups = 10_000
        let lookup = measure {
            for offset in 0..<lookups {
                _ = document.lineAndColumn(at: (offset * 7919) % max(1, length))
            }
        }
        report(size: megabytes, operation: "line/column lookup", seconds: lookup / Double(lookups),
               detail: "per lookup")

        let appendCount = 100
        let append = measure {
            for _ in 0..<appendCount {
                document.replaceText(in: NSRange(location: document.textLength, length: 0), with: "x")
            }
        }
        report(size: megabytes, operation: "append edit", seconds: append / Double(appendCount),
               detail: "per edit, at end")

        let middleCount = 10
        let middleEdit = measure {
            for _ in 0..<middleCount {
                document.replaceText(in: NSRange(location: middle, length: 1), with: "y")
            }
        }
        report(size: megabytes, operation: "middle edit", seconds: middleEdit / Double(middleCount),
               detail: "per edit, one character")

        let nearEndEdit = measure {
            document.replaceText(in: NSRange(location: nearEnd, length: 0), with: "z")
        }
        report(size: megabytes, operation: "near-end insert", seconds: nearEndEdit,
               detail: "one character")

        var snapshot: EditorDocument.Snapshot?
        let snapshotTime = measure {
            snapshot = document.snapshot()
        }
        report(size: megabytes, operation: "save snapshot", seconds: snapshotTime,
               detail: "\(byteCount / 1_000_000) MB copy")

        let encode = try measure {
            _ = try TextIO.encode(snapshot!.text, as: snapshot!.encoding,
                                  withUTF8BOM: snapshot!.hasUTF8BOM)
        }
        report(size: megabytes, operation: "UTF-8 encode", seconds: encode,
               detail: "\(byteCount / 1_000_000) MB")

        // One dirty-line pass at the far end of a Markdown document. This is
        // where a whole-document `storage.string` copy used to happen.
        let storage = NSTextStorage(string: document.text)
        let highlighter = try StorageHighlighter(rules: format.highlightRules,
                                                 scanner: format.scanner,
                                                 theme: EditorTheme())
        let dirtyLocation = max(0, storage.length - 200)
        let dirty = NSRange(location: dirtyLocation, length: 100)
        // Warm the highlighter/storage path; the first call can include lazy
        // NSString materialisation that a real editing session has already done.
        highlighter.apply(to: storage, in: dirty)
        let highlight = measure {
            highlighter.apply(to: storage, in: dirty)
        }
        report(size: megabytes, operation: "dirty-line highlight", seconds: highlight,
               detail: "Markdown, near end")

        let fullStart = storage.length - 50_000
        let fullChunk = measure {
            highlighter.apply(to: storage,
                              in: NSRange(location: fullStart, length: storage.length - fullStart))
        }
        report(size: megabytes, operation: "last 50k highlight chunk", seconds: fullChunk,
               detail: "Markdown, initial-pass chunk")

        let fullPass = measure {
            var state = Tokenizer.State()
            var start = 0
            while start < storage.length {
                let text = storage.mutableString
                let tentativeEnd = min(start + 50_000, storage.length)
                let lineRange = text.lineRange(
                    for: NSRange(location: start, length: tentativeEnd - start))
                let end = min(NSMaxRange(lineRange), storage.length)
                highlighter.apply(to: storage,
                                  in: NSRange(location: start, length: end - start),
                                  state: &state)
                start = end
            }
        }
        report(size: megabytes, operation: "full highlight pass", seconds: fullPass,
               detail: "Markdown, line-aligned chunks")

        // The full pass cached scanner checkpoints. A dirty-line pass near the
        // end now resumes from the nearest checkpoint instead of replaying the
        // whole document prefix.
        let checkpointedHighlight = measure {
            highlighter.apply(to: storage, in: dirty)
        }
        report(size: megabytes, operation: "dirty-line (checkpointed)", seconds: checkpointedHighlight,
               detail: "resumed \(dirty.location - highlighter.lastRecoveryStart) chars back, "
                   + "\(highlighter.checkpointCount) checkpoints")

        #expect(document.numberOfLines > 1)
        #expect(snapshot?.text.utf16.count == document.textLength)
    }

    // MARK: Helpers

    private func measure(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private func report(size: Int, operation: String, seconds: Double, detail: String) {
        let value: Double
        let unit: String
        if seconds < 0.001 {
            value = seconds * 1_000_000
            unit = "µs"
        } else {
            value = seconds * 1_000
            unit = "ms"
        }
        print(String(format: "BENCH %2d MB  %-25@ %9.3f %@  %@",
                     size, operation as NSString, value, unit as NSString, detail))
    }

    /// A realistic Markdown file: headings, emphasis, links and fenced code.
    private static func makeDocument(megabytes: Int) -> String {
        let prose = "# Heading with **bold** and [link](https://example.com)\n"
        let fence = "```swift\nlet value = 42\nprint(\"not a heading\")\n```\n"
        let block = prose + prose + fence + prose
        let targetBytes = megabytes * 1_024 * 1_024
        let blockBytes = max(1, block.lengthOfBytes(using: .utf8))
        return String(repeating: block, count: targetBytes / blockBytes)
    }
}
