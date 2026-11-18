import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let dotSource = UTType(exportedAs: "io.github.hakkabon.dot-source", conformingTo: .plainText)
}

struct DOTDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        // Existing .dot files can have a different registered UTI on a user's
        // device. Validate UTF-8 on opening, regardless of that association.
        [.dotSource, .data]
    }
    static var writableContentTypes: [UTType] { [.dotSource] }
    var text = "digraph {\n    start -> finish\n}\n"

    init() {}

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

@main
struct ModEditPadApp: App {
    init() {
        // Files exposes the app's local location once its Documents directory
        // exists, including on a newly installed simulator.
        _ = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true)
    }

    var body: some Scene {
        DocumentGroup(newDocument: DOTDocument()) { configuration in
            PadEditor(document: configuration.$document)
                .navigationTitle(configuration.fileURL?.lastPathComponent ?? "Untitled.dot")
        }
    }
}
