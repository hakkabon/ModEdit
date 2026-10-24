import Foundation

@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var text: String
    @Published var format: any DocumentFormat

    var encoding: String.Encoding = .utf8

    init(text: String, format: any DocumentFormat) {
        self.text = text
        self.format = format
    }

    init(data: Data, format: any DocumentFormat) throws {
        let decoded = TextIO.decode(data)
        self.text = decoded.text
        self.encoding = decoded.encoding
        self.format = format
    }

    func syncText(_ newText: String) { text = newText }

    func saveData() throws -> Data {
        try TextIO.encode(text, as: encoding)
    }
}
