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
