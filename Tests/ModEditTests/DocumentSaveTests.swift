import Testing
import AppKit
import Foundation
import UniformTypeIdentifiers
@testable import ModEditCore

@Suite("Document saving", .serialized)
@MainActor
struct DocumentSaveTests {

    @Test func snapshotKeepsTextAndGenerationTogetherUnderConcurrency() async {
        let document = EditorDocument()
        document.setText("1")

        let writer = Task.detached {
            for value in 2...2_000 {
                document.setText(String(value))
                try? await Task.sleep(for: .microseconds(50))
            }
        }

        for _ in 0..<2_000 {
            let snapshot = document.snapshot()
            #expect(UInt64(snapshot.text) == snapshot.generation,
                    "text \(snapshot.text.debugDescription) did not match generation \(snapshot.generation)")
            try? await Task.sleep(for: .microseconds(25))
        }
        await writer.value

        let final = document.snapshot()
        #expect(UInt64(final.text) == final.generation)
    }

    @Test func successfulSaveWritesTheFileAndClearsDirtyState() async throws {
        let document = ModEditDocument()
        document.buffer.setText("first")
        #expect(document.buffer.isDirty)

        let url = temporaryURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }

        try await document.saveForTesting(to: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "first")
        #expect(!document.buffer.isDirty)
    }

    @Test func aSecondSaveWritesTheNewerText() async throws {
        let document = ModEditDocument()
        document.buffer.setText("first")
        let url = temporaryURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }

        try await document.saveForTesting(to: url)
        document.buffer.setText("second")
        try await document.saveForTesting(to: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "second")
        #expect(!document.buffer.isDirty)
    }

    @Test func failedSaveLeavesTheDocumentDirty() async {
        let document = ModEditDocument()
        document.buffer.setText("hello")
        let model = EditorModel(document: document.buffer)

        // The parent directory deliberately does not exist, so both the inner
        // atomic write and NSDocument's safe save must fail.
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModEdit-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("missing/file.txt")

        await #expect(throws: (any Error).self) {
            try await document.saveForTesting(to: badURL)
        }
        #expect(document.buffer.isDirty)
        #expect(model.isDocumentDirty)
    }

    @Test func exportingACopyDoesNotClearDirtyState() async throws {
        let document = ModEditDocument()
        document.buffer.setText("draft")
        let model = EditorModel(document: document.buffer)
        let url = temporaryURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }

        try await document.saveForTesting(to: url, for: .saveToOperation)

        #expect(try String(contentsOf: url, encoding: .utf8) == "draft")
        #expect(document.buffer.isDirty)
        #expect(model.isDocumentDirty)
    }

    @Test func autosavingAnUntitledDraftDoesNotMarkItSaved() async throws {
        let document = ModEditDocument()
        document.buffer.setText("draft")
        let model = EditorModel(document: document.buffer)
        let url = temporaryURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }

        try await document.saveForTesting(to: url, for: .autosaveElsewhereOperation)

        #expect(try String(contentsOf: url, encoding: .utf8) == "draft")
        #expect(document.buffer.isDirty)
        #expect(model.isDocumentDirty)
    }

    @Test func readAndWritePreserveEncodingAndBOM() throws {
        let document = ModEditDocument()
        let original = try TextIO.encode("héllo", as: .utf8, withUTF8BOM: true)

        try document.read(from: original, ofType: UTType.plainText.identifier)

        #expect(document.buffer.content.text == "héllo")
        #expect(document.buffer.content.encoding == .utf8)
        #expect(document.buffer.content.hasUTF8BOM)
        #expect(!document.buffer.isDirty)

        let written = try document.data(ofType: UTType.plainText.identifier)
        #expect(written == original)
    }

    @Test func readSelectsTheMarkdownFormatFromTheDocumentType() throws {
        let document = ModEditDocument()

        try document.read(from: Data("# Title".utf8),
                          ofType: UTType.markdownText.identifier)

        #expect(document.buffer.currentFormat.id == "markdown")
    }

    @Test func modelReflectsCompletedSaves() async throws {
        let document = ModEditDocument()
        let model = EditorModel(document: document.buffer)

        document.buffer.setText("one")
        try? await Task.sleep(for: .milliseconds(10))
        #expect(model.isDocumentDirty)

        let url = temporaryURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try await document.saveForTesting(to: url)
        try? await Task.sleep(for: .milliseconds(10))

        #expect(!model.isDocumentDirty)
    }

    // MARK: Helpers

    private func temporaryURL(extension fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ModEdit-\(UUID().uuidString).\(fileExtension)")
    }
}

@MainActor
private extension ModEditDocument {
    func saveForTesting(to url: URL,
                        ofType typeName: String = UTType.plainText.identifier,
                        for operation: NSDocument.SaveOperationType = .saveOperation) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            save(to: url, ofType: typeName, for: operation) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
