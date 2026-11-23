import Testing
import AppKit
@testable import ModEditCore

@Suite("Rendered editor styling", .serialized)
@MainActor
struct RenderedEditorStylerTests {

    @Test func collapsedRunsStayInvisibleWithoutChangingLineHeight() throws {
        let theme = EditorTheme()
        let styler = RenderedEditorStyler(theme: theme, tabSize: 4)
        let source = "# Heading\n\nA **bold** [link](https://example.com)\n"
        let presentation = try RenderedEditorPresentation(source: source)
        let boldLine = presentation.lineRange(
            containing: (source as NSString).range(of: "A **").location)
        let storage = makeStorage(source: source, theme: theme, styler: styler,
                                  presentation: presentation, activeLine: boldLine)

        let hashFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let kern = (storage.attribute(.kern, at: 0, effectiveRange: nil) as? NSNumber)?
            .doubleValue ?? 0
        #expect(isHidden(storage, at: 0))
        #expect(hashFont?.pointSize == theme.baseFont.pointSize)
        #expect(kern < 0)

        let heading = (source as NSString).range(of: "Heading")
        let headingFont = storage.attribute(
            .font, at: heading.location, effectiveRange: nil) as? NSFont
        #expect(headingFont?.pointSize ?? 0 > theme.baseFont.pointSize)
    }

    @Test func linksAndStrikethroughKeepTheirSemantics() throws {
        let theme = EditorTheme()
        let styler = RenderedEditorStyler(theme: theme, tabSize: 4)
        let source = "Text ~~gone~~ and [link](https://example.com)\n"
        let presentation = try RenderedEditorPresentation(source: source)
        let storage = makeStorage(source: source, theme: theme, styler: styler,
                                  presentation: presentation, activeLine: nil)

        let gone = (source as NSString).range(of: "gone")
        #expect(storage.attribute(
            .strikethroughStyle, at: gone.location, effectiveRange: nil) != nil)

        let link = (source as NSString).range(of: "link")
        let underline = storage.attribute(
            .underlineStyle, at: link.location, effectiveRange: nil) as? Int
        #expect(underline == NSUnderlineStyle.single.rawValue)

        let destination = (source as NSString).range(of: "https://example.com")
        #expect(isHidden(storage, at: destination.location))
    }

    @Test func movingTheActiveLineMovesHiddennessWithIt() throws {
        let theme = EditorTheme()
        let styler = RenderedEditorStyler(theme: theme, tabSize: 4)
        let source = "# Heading\n\nA **bold** word.\n"
        let presentation = try RenderedEditorPresentation(source: source)
        let headingLine = presentation.lineRange(containing: 0)
        let marker = (source as NSString).range(of: "**")
        let boldLine = presentation.lineRange(containing: marker.location)

        let storage = makeStorage(source: source, theme: theme, styler: styler,
                                  presentation: presentation, activeLine: boldLine)
        #expect(isHidden(storage, at: 0))
        #expect(!isHidden(storage, at: marker.location))

        storage.setAttributes(
            theme.baseAttributes,
            range: NSRange(location: 0, length: storage.length))
        styler.apply(spans: presentation.spans(activeLine: headingLine),
                     to: storage,
                     clippedTo: 0..<storage.length,
                     source: storage.mutableString)

        #expect(!isHidden(storage, at: 0))
        #expect(isHidden(storage, at: marker.location))
    }

    private func makeStorage(source: String,
                             theme: EditorTheme,
                             styler: RenderedEditorStyler,
                             presentation: RenderedEditorPresentation,
                             activeLine: Range<Int>?) -> NSTextStorage {
        let storage = NSTextStorage(string: source)
        storage.setAttributes(
            theme.baseAttributes,
            range: NSRange(location: 0, length: storage.length))
        styler.apply(spans: presentation.spans(activeLine: activeLine),
                     to: storage,
                     clippedTo: 0..<storage.length,
                     source: storage.mutableString)
        return storage
    }

    private func isHidden(_ storage: NSTextStorage, at location: Int) -> Bool {
        storage.attribute(RenderedEditorStyler.hiddenAttribute,
                          at: location,
                          effectiveRange: nil) != nil
    }
}
