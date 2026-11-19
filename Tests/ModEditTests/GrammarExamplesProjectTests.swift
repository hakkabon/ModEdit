import Foundation
import GrammarLanguage
import Testing
@testable import ModEditCore

@MainActor
@Test func grammarExamplesRoundTripAndProtectExternalEdits() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Examples.json")
    let project = GrammarExamplesProject()
    project.examples = [.init(id: "accepted", input: "enable cache", shouldAccept: true)]
    #expect(project.hasUnsavedChanges)
    try project.save(to: url)
    #expect(!project.hasUnsavedChanges)

    let reopened = GrammarExamplesProject()
    try reopened.load(from: url)
    #expect(reopened.examples == project.examples)
    #expect(!reopened.hasUnsavedChanges)
    reopened.examples[0].input = "disable cache"
    let external = Data(#"{"schemaVersion":1,"examples":[{"id":"external","input":"x","shouldAccept":false}]}"#.utf8)
    try external.write(to: url)
    #expect(throws: (any Error).self) { try reopened.save(to: url) }
    #expect(try Data(contentsOf: url) == external)
    #expect(reopened.hasUnsavedChanges)
}
