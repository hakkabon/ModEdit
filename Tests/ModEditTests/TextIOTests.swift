import Testing
import Foundation
@testable import ModEditCore

@Suite("TextIO")
struct TextIOTests {

    @Test func plainUTF8() throws {
        let decoded = try TextIO.decode(Data("héllo".utf8))
        #expect(decoded.text == "héllo")
        #expect(decoded.encoding == .utf8)
        #expect(!decoded.hasUTF8BOM)
    }

    @Test func utf8BOMIsRemembered() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("héllo".utf8)
        let decoded = try TextIO.decode(original)
        #expect(decoded.text == "héllo")
        #expect(decoded.hasUTF8BOM)

        let written = try TextIO.encode(decoded.text, as: decoded.encoding,
                                        withUTF8BOM: decoded.hasUTF8BOM)
        #expect(written == original)
    }

    @Test func utf16WithBOM() throws {
        let data = try #require("hi".data(using: .utf16))
        let decoded = try TextIO.decode(data)
        #expect(decoded.text == "hi")
        #expect(decoded.encoding == .utf16)
    }

    @Test func emptyData() throws {
        let decoded = try TextIO.decode(Data())
        #expect(decoded.text.isEmpty)
    }

    @Test func lossyEncodingIsRefused() {
        #expect(throws: (any Error).self) {
            _ = try TextIO.encode("日本語", as: .ascii)
        }
    }
}
