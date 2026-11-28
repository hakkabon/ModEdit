import Testing
import AppKit
import RenderedText
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

    @Test func renderedTextUsesTheSelectedFontFamilyAndSize() throws {
        let theme = EditorTheme(fontSize: 17, fontName: "Menlo-Regular")
        let styler = RenderedEditorStyler(theme: theme, tabSize: 4)
        let source = "Plain **bold** text\n"
        let presentation = try RenderedEditorPresentation(source: source)
        let storage = makeStorage(source: source, theme: theme, styler: styler,
                                  presentation: presentation, activeLine: nil)

        let plain = try #require(storage.attribute(
            .font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(plain.pointSize == 17)
        #expect(plain.fontName.hasPrefix("Menlo"))

        let bold = (source as NSString).range(of: "bold")
        let boldFont = try #require(storage.attribute(
            .font, at: bold.location, effectiveRange: nil) as? NSFont)
        #expect(boldFont.pointSize == 17)
        #expect(boldFont.fontName.hasPrefix("Menlo"))
        #expect(boldFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func headingSizesScaleWithTheSelectedBaseSize() throws {
        let source = "# Heading\n"
        let presentation = try RenderedEditorPresentation(source: source)
        let heading = (source as NSString).range(of: "Heading")

        func headingFont(baseSize: CGFloat) throws -> NSFont {
            let theme = EditorTheme(fontSize: baseSize)
            let styler = RenderedEditorStyler(theme: theme, tabSize: 4)
            let storage = makeStorage(source: source, theme: theme,
                                      styler: styler,
                                      presentation: presentation,
                                      activeLine: nil)
            return try #require(storage.attribute(
                .font, at: heading.location,
                effectiveRange: nil) as? NSFont)
        }

        let normal = try headingFont(baseSize: 13)
        let large = try headingFont(baseSize: 20)

        #expect(normal.pointSize > 13)
        #expect(large.pointSize > normal.pointSize)
        let expectedRatio = 20.0 / 13.0
        #expect(abs(large.pointSize / normal.pointSize - expectedRatio) < 0.01)
    }

    @Test func taskCheckboxesSelectAFallbackFont() throws {
        let theme = EditorTheme()
        let styler = RenderedEditorStyler(theme: theme, tabSize: 4)
        let source = "- [ ] task\n"
        let presentation = try RenderedEditorPresentation(source: source)
        let storage = makeStorage(source: source, theme: theme, styler: styler,
                                  presentation: presentation, activeLine: nil)
        let marker = (source as NSString).range(of: "[ ]").location
        let font = try #require(storage.attribute(.font, at: marker,
                                                  effectiveRange: nil) as? NSFont)

        #expect(font.fontName != theme.baseFont.fontName)
        #expect(font.pointSize == theme.baseFont.pointSize)
    }

    @Test func unrenderableDisplayTextKeepsTheBaseFont() {
        let theme = EditorTheme()
        let styler = RenderedEditorStyler(theme: theme, tabSize: 4)
        let span = RenderedEditorSpan(
            sourceRange: 0..<8,
            isHidden: false,
            isRaw: false,
            displayText: "\u{E000}",
            isSubstitution: true,
            role: .text,
            attributes: RenderedAttributes())

        let font = styler.attributes(for: span)[.font] as? NSFont
        #expect(font?.fontName == theme.baseFont.fontName)
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
