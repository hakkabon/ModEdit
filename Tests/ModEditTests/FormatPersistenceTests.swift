import Testing
import AppKit
import Foundation
import UniformTypeIdentifiers
@testable import ModEditCore

@Suite("Format persistence", .serialized)
@MainActor
struct FormatPersistenceTests {

    @Test func savedChoiceOverridesTheFileExtension() throws {
        let store = InMemoryFormatPreferenceStore()
        let url = temporaryURL(extension: "md")
        store.setFormatID("latex", for: url)

        let document = ModEditDocument(registry: .standard, formatStore: store)
        document.fileURL = url
        try document.read(from: Data("\\alpha".utf8),
                          ofType: UTType.markdownText.identifier)

        #expect(document.buffer.currentFormat.id == "latex")
    }

    @Test func unknownSavedChoiceFallsBackToTheFileType() throws {
        let store = InMemoryFormatPreferenceStore()
        let url = temporaryURL(extension: "md")
        store.setFormatID("retired-format", for: url)

        let document = ModEditDocument(registry: .standard, formatStore: store)
        document.fileURL = url
        try document.read(from: Data("# Title".utf8),
                          ofType: UTType.markdownText.identifier)

        #expect(document.buffer.currentFormat.id == "markdown")
    }

    @Test func formatChangeIsRememberedAcrossReopen() throws {
        let store = InMemoryFormatPreferenceStore()
        let url = temporaryURL(extension: "md")
        try Data("# Title".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = ModEditDocument(registry: .standard, formatStore: store)
        document.fileURL = url
        try document.read(from: url, ofType: UTType.markdownText.identifier)
        document.applyFormatChange(HTMLFormat())

        #expect(store.formatID(for: url) == "html")
        #expect(document.fileType == UTType.html.identifier)

        let reopened = ModEditDocument(registry: .standard, formatStore: store)
        try reopened.read(from: url, ofType: UTType.markdownText.identifier)

        #expect(reopened.buffer.currentFormat.id == "html")
    }

    @Test func savingRemembersTheChoiceForANewURL() async throws {
        let store = InMemoryFormatPreferenceStore()
        let url = temporaryURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let document = ModEditDocument(registry: .standard, formatStore: store)
        document.buffer.setFormat(LaTeXFormat())
        try await document.saveForFormatTest(to: url)

        #expect(store.formatID(for: url) == "latex")

        let reopened = ModEditDocument(registry: .standard, formatStore: store)
        try reopened.read(from: url, ofType: UTType.plainText.identifier)

        #expect(reopened.buffer.currentFormat.id == "latex")
    }

    @Test func unregisteredFormatsAreNotPersisted() throws {
        let store = InMemoryFormatPreferenceStore()
        let url = temporaryURL(extension: "txt")

        let document = ModEditDocument(registry: .standard, formatStore: store)
        document.fileURL = url
        document.applyFormatChange(UnregisteredFormat())

        #expect(store.formatID(for: url) == nil)
    }

    @Test func userDefaultsStoreNormalizesPaths() throws {
        let suite = "ModEditTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsFormatStore(defaults: defaults, keyPrefix: "test.")
        let messy = URL(fileURLWithPath: "/tmp/../tmp/note.md")
        let clean = URL(fileURLWithPath: "/tmp/note.md")

        store.setFormatID("html", for: messy)
        #expect(store.formatID(for: clean) == "html")

        store.setFormatID(nil, for: clean)
        #expect(store.formatID(for: messy) == nil)
    }

    private func temporaryURL(extension fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ModEdit-\(UUID().uuidString).\(fileExtension)")
    }
}

private struct UnregisteredFormat: DocumentFormat {
    let id = "unregistered"
    let displayName = "Unregistered"
    let contentTypes: [UTType] = [.plainText]
    let fileExtensions = ["txt"]
    var highlightRules: [HighlightRule] { [] }
    func makePreviewRenderer() -> (any PreviewRenderer)? { nil }
}

@MainActor
private extension ModEditDocument {
    func saveForFormatTest(to url: URL,
                           ofType typeName: String = UTType.plainText.identifier) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            save(to: url, ofType: typeName, for: .saveOperation) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
