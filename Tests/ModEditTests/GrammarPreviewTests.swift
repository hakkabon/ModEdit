import Foundation
import Testing
@testable import ModEditCore

@Test func grammarPreviewRendersRailroadAndReportsInvalidDraft() async throws {
    let renderer = try #require(GrammarFormat().makePreviewRenderer())
    let html = try await renderer.renderHTML(from: #"<start> ::= "a" | "b" ;"#)
    #expect(html.contains("data:image/png;base64,"))
    #expect(html.contains("<h2>start</h2>"))

    let invalid = try await renderer.renderHTML(from: "<start> ::=")
    #expect(invalid.contains("Grammar diagnostics"))
    #expect(!invalid.contains("data:image/png;base64,"))
}

@Test func starterProjectGrammarRendersInModEdit() async throws {
    let project = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Examples/FeatureFlags")
    let source = try String(contentsOf: project.appendingPathComponent("FeatureFlags.bnf"),
                            encoding: .utf8)
    let renderer = try #require(GrammarFormat().makePreviewRenderer())
    let html = try await renderer.renderHTML(from: source)
    for rule in ["file", "command", "action", "feature"] {
        #expect(html.contains("alt=\"Railroad diagram for \(rule)\""))
    }
    #expect(!html.contains("Grammar diagnostics"))

    let draft = try String(
        contentsOf: project.appendingPathComponent("Drafts/RemoveDisable.bnf"), encoding: .utf8)
    let edited = try await renderer.renderHTML(from: draft)
    #expect(edited.contains("alt=\"Railroad diagram for action\""))
}
