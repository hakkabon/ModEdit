import Foundation
import PL0Language
import Testing
@testable import ModEditCore

@Suite("PL/0 workbench adapter", .serialized)
struct PL0WorkbenchAdapterTests {
    @Test func projectsEngineResultsWithoutOwningParserStateInTheView() async {
        let adapter = PL0WorkbenchAdapter(engine: .referenceLL)
        let analysis = await adapter.analyze(SourceSnapshot(
            version: 1, text: "var x; begin x := 1 end."))

        #expect(analysis.parse.version == 1)
        #expect(analysis.recognizers.map(\.id) == [
            "reference-ll", "generated-slr", "earley-chart",
        ])
        #expect(analysis.recognizers.allSatisfy { $0.accepted })
    }

    @Test func retainsLanguageKitSessionAcrossVersionedEdits() async {
        let adapter = PL0WorkbenchAdapter()
        let original = "var x; begin x := 1 end."
        _ = await adapter.analyze(SourceSnapshot(version: 4, text: original))
        let location = (original as NSString).range(of: "1").location
        let edited = (original as NSString).replacingCharacters(
            in: NSRange(location: location, length: 1), with: "2")
        let analysis = await adapter.analyze(SourceSnapshot(
            version: 5,
            text: edited,
            edit: SourceEdit(baseVersion: 4,
                             replacedRange: SourceRange(location: location, length: 1),
                             replacementLength: 1)))

        #expect(analysis.parse.version == 5)
        #expect(analysis.parse.metrics.incrementalLexing.incremental)
        #expect(analysis.parse.metrics.incrementalParsing.incremental)
    }
}
