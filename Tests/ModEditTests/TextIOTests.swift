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
        #expect(decoded.encoding == .utf16LittleEndian)
        #expect(decoded.byteOrderMark == .utf16LittleEndian)
        #expect(try TextIO.encode(decoded.text, as: decoded.encoding,
                                  byteOrderMark: decoded.byteOrderMark) == data)
    }

    @Test func utf16LittleEndianBOMRoundTripsExactly() throws {
        let body = try #require("héllo 👩🏽‍💻".data(using: .utf16LittleEndian))
        let original = Data([0xFF, 0xFE]) + body

        let decoded = try TextIO.decode(original)

        #expect(decoded.text == "héllo 👩🏽‍💻")
        #expect(decoded.encoding == .utf16LittleEndian)
        #expect(decoded.byteOrderMark == .utf16LittleEndian)
        #expect(try TextIO.encode(decoded.text, as: decoded.encoding,
                                  byteOrderMark: decoded.byteOrderMark) == original)
    }

    @Test func utf16BigEndianBOMRoundTripsExactly() throws {
        let body = try #require("héllo 👩🏽‍💻".data(using: .utf16BigEndian))
        let original = Data([0xFE, 0xFF]) + body

        let decoded = try TextIO.decode(original)

        #expect(decoded.text == "héllo 👩🏽‍💻")
        #expect(decoded.encoding == .utf16BigEndian)
        #expect(decoded.byteOrderMark == .utf16BigEndian)
        #expect(try TextIO.encode(decoded.text, as: decoded.encoding,
                                  byteOrderMark: decoded.byteOrderMark) == original)
    }

    @Test func bomlessUTF16IsDetectedAndKeepsItsByteOrder() throws {
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            let original = try #require("hi there".data(using: encoding))
            let decoded = try TextIO.decode(original)

            #expect(decoded.text == "hi there")
            #expect(decoded.encoding == encoding)
            #expect(decoded.byteOrderMark == nil)
            #expect(try TextIO.encode(decoded.text, as: decoded.encoding) == original)
        }
    }

    @Test func bomOnlyFilesSurviveARoundTrip() throws {
        let utf8 = Data([0xEF, 0xBB, 0xBF])
        let decodedUTF8 = try TextIO.decode(utf8)
        #expect(decodedUTF8.text.isEmpty)
        #expect(decodedUTF8.byteOrderMark == .utf8)
        #expect(try TextIO.encode(decodedUTF8.text, as: decodedUTF8.encoding,
                                  byteOrderMark: decodedUTF8.byteOrderMark) == utf8)

        let utf16 = Data([0xFF, 0xFE])
        let decodedUTF16 = try TextIO.decode(utf16)
        #expect(decodedUTF16.text.isEmpty)
        #expect(decodedUTF16.encoding == .utf16LittleEndian)
        #expect(try TextIO.encode(decodedUTF16.text, as: decodedUTF16.encoding,
                                  byteOrderMark: decodedUTF16.byteOrderMark) == utf16)
    }

    @Test func legacyEncodingRoundTripsItsBytes() throws {
        // "café" in Windows-1252; the byte 0xE9 is not valid UTF-8.
        let original = Data([0x63, 0x61, 0x66, 0xE9])
        let decoded = try TextIO.decode(original)

        #expect(decoded.text == "café")
        #expect(decoded.encoding == .windowsCP1252)
        #expect(decoded.byteOrderMark == nil)
        #expect(try TextIO.encode(decoded.text, as: decoded.encoding) == original)
    }

    @Test func malformedUTF16BOMIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try TextIO.decode(Data([0xFF, 0xFE, 0x00]))
        }
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
