import DOTLanguage
import IncrementalParsing
import Testing
@testable import ModEditCore

@Test func dotPreviewLaysOutLabelsAndRetainsTheLastDrawableRevision() async throws {
    let source = #"""
        digraph {
            a [label="Start"]
            a -> b [label="first"]
            a -> b [label="second"]
            b -> a [label="return"]
            b -> b [label="loop"]
        }
        """#
    let session = DOTProviderSession()
    let preview = try await session.analyzeGraph(.init(text: source, revision: .init(1)))
    guard case .graph(let graph) = preview else {
        Issue.record("Expected a drawable graph")
        return
    }
    let layout = DOTPreviewLayout()
    let drawing = try await layout.draw(graph)
    #expect(drawing.directed)
    #expect(drawing.nodes.count == 2)
    #expect(drawing.nodes.contains { $0.source.label == "Start" && $0.source.range.length == 1 })
    #expect(drawing.routes.count == 4)
    #expect(drawing.routes.contains { $0.isSelfLoop })
    #expect(Set(drawing.routes.compactMap { drawing.edgeLabels[$0.id] }) == ["first", "second", "return", "loop"])
    #expect(drawing.routes.allSatisfy { !$0.segments.isEmpty && $0.labelPosition != nil })
    #expect(!drawing.bounds.isEmpty)

    var display = DOTPreviewDisplay()
    display.show(drawing, revision: 1)
    #expect(display.canReveal(at: 1))
    let invalid = try await session.analyzeGraph(.init(text: "digraph { a ->", revision: .init(2)))
    #expect(invalid == .invalid)
    display.report("Check Problems for the current DOT errors.")
    #expect(display.drawing?.nodes.count == 2)
    #expect(display.message?.hasPrefix("Showing the previous graph.") == true)
    #expect(!display.canReveal(at: 2))

    let fixed = try await session.analyzeGraph(.init(text: "graph { a -- b }", revision: .init(3)))
    guard case .graph(let undirected) = fixed else {
        Issue.record("Expected a drawable undirected graph")
        return
    }
    let updated = try await layout.draw(undirected)
    display.show(updated, revision: 3)
    #expect(display.message == nil)
    #expect(display.canReveal(at: 3))
    #expect(display.drawing?.directed == false)
}

@Test func dotFormatOffersNativePreview() {
    let format = DOTFormat()
    #expect(format.supportsPreview)
    #expect(format.makePreviewRenderer() == nil)
}
