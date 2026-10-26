import Foundation

/// Cached UTF-16 offsets for logical line starts (LF, CRLF and CR).
struct LineIndex {
    private(set) var starts: [Int] = [0]

    init(text: String = "") { rebuild(from: text) }

    mutating func rebuild(from source: String) {
        let text = source as NSString
        starts = [0]
        var index = 0
        while index < text.length {
            let character = text.character(at: index)
            if character == 0x0D {
                if index + 1 < text.length, text.character(at: index + 1) == 0x0A { index += 1 }
                starts.append(index + 1)
            } else if character == 0x0A {
                starts.append(index + 1)
            }
            index += 1
        }
    }

    func lineAndColumn(at location: Int) -> (line: Int, column: Int) {
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if starts[middle] <= location { lower = middle + 1 } else { upper = middle }
        }
        let index = max(0, lower - 1)
        return (index + 1, max(1, location - starts[index]))
    }
}
