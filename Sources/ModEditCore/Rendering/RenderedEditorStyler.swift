import AppKit
import CoreText

/// Turns platform-neutral rendered presentation into AppKit attributes.
///
/// Collapsed syntax keeps its characters in storage (so source offsets, undo
/// and saving are untouched) and is made invisible with a clear colour and a
/// negative kern that reduces every hidden glyph's advance to zero. The font
/// stays at its normal size, so hiding a reference definition or a fence line
/// does not collapse the line's height.
@MainActor
final class RenderedEditorStyler {
    /// Marker used by tests and by the coordinator to detect stale hidden
    /// attributes. Hiddenness is also visible through `.kern` and the clear
    /// foreground colour.
    static let hiddenAttribute = NSAttributedString.Key(
        "io.github.hakkabon.ModEdit.rendered-hidden")

    private struct FontKey: Hashable {
        let size: CGFloat
        let bold: Bool
        let italic: Bool
    }

    private struct FallbackFontKey: Hashable {
        let text: String
        let baseFontName: String
        let size: CGFloat
    }

    private static let headingBaseSizes: [CGFloat] = [22, 19, 17, 15.5, 14.5, 13.5]

    private let theme: EditorTheme
    private let tabSize: Int
    private let baseFont: NSFont
    private let spaceAdvance: CGFloat
    private let codeBackgroundColor: NSColor
    private let headingSizes: [CGFloat]
    private var fonts: [FontKey: NSFont] = [:]
    private var fallbackFonts: [FallbackFontKey: NSFont] = [:]
    private var missingFallbackFonts: Set<FallbackFontKey> = []

    init(theme: EditorTheme, tabSize: Int) {
        self.theme = theme
        self.tabSize = max(1, tabSize)
        self.baseFont = theme.baseFont
        self.spaceAdvance = theme.baseFont.maximumAdvancement.width
        self.codeBackgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.22)
        // Headings stay proportionate when the user chooses another size.
        let scale = theme.baseFont.pointSize / EditorSettings.defaultFontSize
        self.headingSizes = Self.headingBaseSizes.map { $0 * scale }
    }

    /// Applies every non-raw span, clipped to `range`.
    ///
    /// The caller is responsible for resetting `range` to the theme's base
    /// attributes first. Raw spans (the caret line) are deliberately skipped so
    /// the host can lay syntax colouring over literal source.
    func apply(spans: [RenderedEditorSpan],
               to storage: NSTextStorage,
               clippedTo range: Range<Int>,
               source: NSString) {
        for span in spans where !span.isRaw {
            let lower = max(span.sourceRange.lowerBound, range.lowerBound)
            let upper = min(span.sourceRange.upperBound, range.upperBound)
            guard lower < upper else { continue }
            let clipped = NSRange(location: lower, length: upper - lower)
            if span.isHidden {
                applyHidden(to: storage, range: clipped, source: source)
            } else {
                storage.addAttributes(attributes(for: span), range: clipped)
            }
        }
    }

    /// Attributes for one visible run.
    func attributes(for span: RenderedEditorSpan) -> [NSAttributedString.Key: Any] {
        let semantic = span.attributes
        var attributes = theme.baseAttributes

        var size = theme.baseFont.pointSize
        if let level = semantic.headingLevel {
            size = headingSizes[min(max(level, 1), headingSizes.count) - 1]
        }
        let bold = semantic.isStrong || semantic.headingLevel != nil
        let italic = semantic.isEmphasis
        var color = theme.defaultTextColor

        if semantic.isCode {
            color = theme.color(for: .code)
        }
        if semantic.isBlockQuote {
            color = theme.color(for: .quote)
        }
        if semantic.headingLevel != nil {
            color = theme.color(for: .heading)
        }
        if semantic.isHTML {
            color = theme.color(for: .comment)
        }
        if semantic.isImage {
            color = theme.color(for: .comment)
        }
        if span.role == .tableSeparator {
            color = theme.color(for: .comment)
        }
        if span.role == .thematicBreak {
            color = theme.color(for: .heading)
        }
        if semantic.isLink {
            color = theme.color(for: .link)
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            if let destination = semantic.linkDestination, !destination.isEmpty {
                attributes[.toolTip] = destination
            }
        }
        if semantic.isStrikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = color
        }
        if semantic.isCode {
            attributes[.backgroundColor] = codeBackgroundColor
        }
        if span.role == .listMarker {
            color = theme.color(for: .listMarker)
        }

        let base = font(size: size, bold: bold, italic: italic)
        if span.isSubstitution,
           let fallback = substitutionFont(for: span.displayText, base: base) {
            attributes[.font] = fallback
        } else {
            attributes[.font] = base
        }
        attributes[.foregroundColor] = color
        return attributes
    }

    /// A font that can draw the whole display string, or `nil` when the base
    /// font already can or no installed font has every glyph.
    ///
    /// The editor's monospaced font intentionally lacks some symbols (the
    /// unchecked task box, for example). CoreText finds a fallback such as
    /// Menlo or the emoji font; the layout manager's glyph substitution then
    /// uses that font for the substituted slots. Keeping the base font when no
    /// fallback covers the string preserves the source spelling rather than
    /// drawing a missing-glyph box.
    private func substitutionFont(for text: String, base: NSFont) -> NSFont? {
        guard !text.isEmpty else { return nil }
        let key = FallbackFontKey(text: text, baseFontName: base.fontName,
                                  size: base.pointSize)
        if let cached = fallbackFonts[key] { return cached }
        if missingFallbackFonts.contains(key) { return nil }

        let units = Array(text.utf16)
        guard units.count == text.unicodeScalars.count else {
            missingFallbackFonts.insert(key)
            return nil
        }
        let string = text as NSString
        let fallback = CTFontCreateForString(
            base as CTFont, string, CFRange(location: 0, length: string.length)) as NSFont
        guard fallback.fontName != base.fontName else {
            // The base font already covers the string; use it directly.
            fallbackFonts[key] = fallback
            return fallback
        }
        guard fallback.fontName != "LastResort",
              fallback.fontName != ".LastResort" else {
            // LastResort only draws a blank fallback box. Keeping the source
            // spelling is more useful than a tofu character.
            missingFallbackFonts.insert(key)
            return nil
        }

        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        let found = units.withUnsafeBufferPointer { characters in
            glyphs.withUnsafeMutableBufferPointer { buffer in
                CTFontGetGlyphsForCharacters(
                    fallback as CTFont, characters.baseAddress!, buffer.baseAddress!,
                    units.count)
            }
        }
        guard found, !glyphs.contains(0) else {
            missingFallbackFonts.insert(key)
            return nil
        }
        fallbackFonts[key] = fallback
        return fallback
    }

    private func applyHidden(to storage: NSTextStorage,
                             range: NSRange,
                             source: NSString) {
        guard range.length > 0 else { return }
        var cursor = range.location
        let end = NSMaxRange(range)
        while cursor < end {
            let composed = source.rangeOfComposedCharacterSequence(at: cursor)
            let next = min(NSMaxRange(composed), end)
            guard next > cursor else { break }
            let characterRange = NSRange(location: cursor, length: next - cursor)
            let character = source.substring(with: characterRange)
            // A tab's width depends on the next tab stop, not on its glyph.
            // The editor's paragraph style uses `tabSize` spaces per stop, so
            // cancelling that advance keeps hidden indentation at zero width.
            let advance = character == "\t"
                ? spaceAdvance * CGFloat(tabSize)
                : (character as NSString).size(withAttributes: [.font: baseFont]).width
            storage.addAttributes([
                .font: baseFont,
                .foregroundColor: NSColor.clear,
                .kern: -advance,
                Self.hiddenAttribute: true,
            ], range: characterRange)
            cursor = next
        }
    }

    private func font(size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        let key = FontKey(size: size, bold: bold, italic: italic)
        if let cached = fonts[key] { return cached }

        let font = theme.font(ofSize: size, bold: bold, italic: italic)
        fonts[key] = font
        return font
    }
}
