import SwiftUI
import UniformTypeIdentifiers

final class EditorDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] {
        [.plainText, .utf8PlainText, .markdown, .html, .xml, .json, .yaml]
    }
    static var writableContentTypes: [UTType] { readableContentTypes }

    @Published var model: EditorModel

    init() {
        model = EditorModel(text: "", format: PlainTextFormat())
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadNoPermission)
        }
        let format = FormatRegistry.shared.format(for: configuration.contentType)
        model = try EditorModel(data: data, format: format)
    }

    func snapshot(contentType: UTType) throws -> EditorModel { model }

    func fileWrapper(snapshot: EditorModel,
                     configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try snapshot.saveData())
    }
}
