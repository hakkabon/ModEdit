import Foundation

/// Decoding and encoding of text files, preserving the original encoding so a
/// file is written back the way it was read.
enum TextIO {

    /// The result of decoding a file.
    struct Decoded: Equatable, Sendable {
        var text: String
        var encoding: String.Encoding
        /// Whether the file started with a UTF-8 byte-order mark, so it can be
        /// written back (dropping it silently would change the file).
        var hasUTF8BOM: Bool
    }

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Decodes `data`, detecting the encoding.
    ///
    /// Order: UTF-8 BOM, UTF-16 BOM, *strict* UTF-8, then Foundation's
    /// heuristic detector. Strict UTF-8 comes before the heuristic because the
    /// detector can misjudge valid UTF-8.
    ///
    /// - Throws: `CocoaError(.fileReadInapplicableStringEncoding)` rather than
    ///   returning replacement characters, which would corrupt the file on save.
    static func decode(_ data: Data) throws -> Decoded {
        if data.isEmpty {
            return Decoded(text: "", encoding: .utf8, hasUTF8BOM: false)
        }
        if data.starts(with: utf8BOM) {
            guard let text = String(data: data.dropFirst(utf8BOM.count), encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return Decoded(text: text, encoding: .utf8, hasUTF8BOM: true)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return Decoded(text: text, encoding: .utf16, hasUTF8BOM: false)
        }
        if let text = String(data: data, encoding: .utf8) {
            return Decoded(text: text, encoding: .utf8, hasUTF8BOM: false)
        }

        var converted: NSString?
        var lossy = ObjCBool(false)
        let raw = NSString.stringEncoding(for: data,
                                          encodingOptions: nil,
                                          convertedString: &converted,
                                          usedLossyConversion: &lossy)
        if raw != 0, !lossy.boolValue, let converted {
            return Decoded(text: converted as String,
                           encoding: String.Encoding(rawValue: raw),
                           hasUTF8BOM: false)
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    /// Encodes `text`, failing instead of losing characters.
    static func encode(_ text: String,
                       as encoding: String.Encoding,
                       withUTF8BOM: Bool = false) throws -> Data {
        guard var data = text.data(using: encoding, allowLossyConversion: false) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        if withUTF8BOM && encoding == .utf8 {
            data.insert(contentsOf: utf8BOM, at: 0)
        }
        return data
    }
}
