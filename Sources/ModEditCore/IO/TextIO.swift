import Foundation

enum TextIO {
    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding) {
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return (String(decoding: data.dropFirst(3), as: UTF8.self), .utf8)
        }
        var used: NSString.Encoding = .utf8
        if NSString.stringEncoding(for: data, encodingOptions: nil,
                                   convertedString: nil, usedEncoding: &used),
           let s = String(data: data, encoding: String.Encoding(rawValue: used.rawValue)) {
            return (s, String.Encoding(rawValue: used.rawValue))
        }
        return (String(decoding: data, as: UTF8.self), .utf8)
    }

    static func encode(_ text: String, as encoding: String.Encoding) throws -> Data {
        guard let data = text.data(using: encoding, allowLossyConversion: false) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return data
    }
}
