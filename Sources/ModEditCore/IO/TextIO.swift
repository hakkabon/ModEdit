import Foundation

/// Decoding and encoding of text files, preserving the original encoding and
/// byte-order mark so a file is written back the way it was read.
enum TextIO {

    /// A byte-order mark that was present in the source file.
    ///
    /// The encoding is kept separate from the BOM: UTF-16 is written with the
    /// source's byte order, and a file that had no BOM does not gain one on
    /// save.
    enum ByteOrderMark: Equatable, Sendable {
        case utf8
        case utf16LittleEndian
        case utf16BigEndian

        var bytes: [UInt8] {
            switch self {
            case .utf8: return [0xEF, 0xBB, 0xBF]
            case .utf16LittleEndian: return [0xFF, 0xFE]
            case .utf16BigEndian: return [0xFE, 0xFF]
            }
        }

        var encoding: String.Encoding {
            switch self {
            case .utf8: return .utf8
            case .utf16LittleEndian: return .utf16LittleEndian
            case .utf16BigEndian: return .utf16BigEndian
            }
        }
    }

    /// The result of decoding a file.
    struct Decoded: Equatable, Sendable {
        var text: String
        var encoding: String.Encoding
        var byteOrderMark: ByteOrderMark?

        /// Convenience for callers that only care about UTF-8.
        var hasUTF8BOM: Bool { byteOrderMark == .utf8 }
    }

    /// Decodes `data`, detecting the encoding.
    ///
    /// Order: UTF-8 BOM, UTF-16 BOM, BOM-less UTF-16 with a clear zero-byte
    /// pattern, *strict* UTF-8, then Foundation's heuristic detector. Strict
    /// UTF-8 comes before the heuristic because the detector can misjudge valid
    /// UTF-8. BOM-less UTF-16 must come before UTF-8 because ASCII UTF-16 is
    /// valid UTF-8 full of NUL characters.
    ///
    /// - Throws: `CocoaError(.fileReadInapplicableStringEncoding)` rather than
    ///   returning replacement characters, which would corrupt the file on save.
    static func decode(_ data: Data) throws -> Decoded {
        if data.isEmpty {
            return Decoded(text: "", encoding: .utf8, byteOrderMark: nil)
        }
        if data.starts(with: ByteOrderMark.utf8.bytes) {
            return try decode(data.dropFirst(ByteOrderMark.utf8.bytes.count),
                              as: .utf8,
                              byteOrderMark: .utf8)
        }
        if data.starts(with: ByteOrderMark.utf16LittleEndian.bytes) {
            return try decodeUTF16(data.dropFirst(ByteOrderMark.utf16LittleEndian.bytes.count),
                                   as: .utf16LittleEndian,
                                   byteOrderMark: .utf16LittleEndian)
        }
        if data.starts(with: ByteOrderMark.utf16BigEndian.bytes) {
            return try decodeUTF16(data.dropFirst(ByteOrderMark.utf16BigEndian.bytes.count),
                                   as: .utf16BigEndian,
                                   byteOrderMark: .utf16BigEndian)
        }
        if let bomless = decodeBOMLessUTF16(data) {
            return bomless
        }
        if let text = String(data: data, encoding: .utf8) {
            return Decoded(text: text, encoding: .utf8, byteOrderMark: nil)
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
                           byteOrderMark: nil)
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    /// Encodes `text`, failing instead of losing characters.
    ///
    /// When `byteOrderMark` is present its encoding takes precedence, so a
    /// UTF-16LE document is never silently rewritten as native-endian UTF-16.
    static func encode(_ text: String,
                       as encoding: String.Encoding,
                       byteOrderMark: ByteOrderMark? = nil) throws -> Data {
        let effectiveEncoding = byteOrderMark?.encoding ?? encoding
        guard var data = text.data(using: effectiveEncoding,
                                   allowLossyConversion: false) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        if let byteOrderMark {
            data.insert(contentsOf: byteOrderMark.bytes, at: 0)
        }
        return data
    }

    /// Compatibility helper for callers that only use a UTF-8 BOM.
    static func encode(_ text: String,
                       as encoding: String.Encoding,
                       withUTF8BOM: Bool) throws -> Data {
        try encode(text, as: encoding, byteOrderMark: withUTF8BOM ? .utf8 : nil)
    }

    // MARK: Private

    private static func decode(_ payload: Data,
                               as encoding: String.Encoding,
                               byteOrderMark: ByteOrderMark?) throws -> Decoded {
        guard let text = String(data: payload, encoding: encoding) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return Decoded(text: text, encoding: encoding, byteOrderMark: byteOrderMark)
    }

    private static func decodeUTF16(_ payload: Data,
                                    as encoding: String.Encoding,
                                    byteOrderMark: ByteOrderMark) throws -> Decoded {
        guard payload.count.isMultiple(of: 2) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return try decode(payload, as: encoding, byteOrderMark: byteOrderMark)
    }

    /// Detects UTF-16 without a BOM when every NUL byte is on the same side of
    /// a code unit. That is exactly the signature of ASCII/Latin text encoded
    /// as UTF-16; requiring an exact re-encode prevents misclassifying ordinary
    /// UTF-8 text that merely contains a NUL.
    private static func decodeBOMLessUTF16(_ data: Data) -> Decoded? {
        guard data.count >= 2, data.count.isMultiple(of: 2) else { return nil }

        var evenNULs = 0
        var oddNULs = 0
        for index in data.indices where data[index] == 0 {
            if index.isMultiple(of: 2) {
                evenNULs += 1
            } else {
                oddNULs += 1
            }
        }

        let encoding: String.Encoding
        if oddNULs > 0, evenNULs == 0 {
            encoding = .utf16LittleEndian
        } else if evenNULs > 0, oddNULs == 0 {
            encoding = .utf16BigEndian
        } else {
            return nil
        }

        guard let text = String(data: data, encoding: encoding),
              !text.contains("\0"),
              text.data(using: encoding, allowLossyConversion: false) == data else {
            return nil
        }
        return Decoded(text: text, encoding: encoding, byteOrderMark: nil)
    }
}
