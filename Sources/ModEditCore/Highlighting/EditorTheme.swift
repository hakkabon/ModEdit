import AppKit

/// Maps semantic `TokenKind`s to fonts and colours.
///
/// The palette has explicit light and dark variants. Each exposed colour is an
/// adaptive `NSColor`, so AppKit resolves it against the appearance in effect
/// when the text is drawn; switching appearance does not require rebuilding the
/// attributed text. Test code can inspect the concrete palettes with
/// `palette(for:)`.
struct EditorTheme {

    /// All colours used by one appearance.
    struct Palette {
        let background: NSColor
        let text: NSColor
        let currentLine: NSColor
        let gutterBackground: NSColor
        let gutterText: NSColor
        let gutterCurrentLine: NSColor
        let gutterCurrentLineText: NSColor
        let insertionPoint: NSColor
        private let tokenColors: [TokenKind: NSColor]

        init(background: NSColor,
             text: NSColor,
             currentLine: NSColor,
             gutterBackground: NSColor,
             gutterText: NSColor,
             gutterCurrentLine: NSColor,
             gutterCurrentLineText: NSColor,
             insertionPoint: NSColor,
             tokenColors: [TokenKind: NSColor]) {
            self.background = background
            self.text = text
            self.currentLine = currentLine
            self.gutterBackground = gutterBackground
            self.gutterText = gutterText
            self.gutterCurrentLine = gutterCurrentLine
            self.gutterCurrentLineText = gutterCurrentLineText
            self.insertionPoint = insertionPoint
            self.tokenColors = tokenColors
        }

        func color(for kind: TokenKind) -> NSColor {
            tokenColors[kind] ?? text
        }
    }

    static let light = Palette(
        background: rgb(0xFF, 0xFF, 0xFF),
        text: rgb(0x1F, 0x23, 0x28),
        currentLine: rgb(0x00, 0x00, 0x00, alpha: 0.045),
        gutterBackground: rgb(0xF6, 0xF8, 0xFA),
        gutterText: rgb(0x59, 0x63, 0x6E),
        gutterCurrentLine: rgb(0xEA, 0xEE, 0xF2),
        gutterCurrentLineText: rgb(0x05, 0x50, 0xAE),
        insertionPoint: rgb(0x1F, 0x23, 0x28),
        tokenColors: [
            .comment: rgb(0x59, 0x63, 0x6E),
            .tag: rgb(0x05, 0x50, 0xAE),
            .attributeName: rgb(0x82, 0x50, 0xDF),
            .string: rgb(0xBC, 0x4C, 0x00),
            .command: rgb(0x82, 0x50, 0xDF),
            .math: rgb(0x0F, 0x6F, 0x74),
            .argument: rgb(0x05, 0x50, 0xAE),
            .optionalArgument: rgb(0xBC, 0x4C, 0x00),
            .heading: rgb(0x05, 0x50, 0xAE),
            .strong: rgb(0x1F, 0x23, 0x28),
            .code: rgb(0xBF, 0x39, 0x89),
            .link: rgb(0x09, 0x69, 0xDA),
            .quote: rgb(0x59, 0x63, 0x6E),
            .listMarker: rgb(0xBC, 0x4C, 0x00),
        ])

    static let dark = Palette(
        background: rgb(0x0D, 0x11, 0x17),
        text: rgb(0xE6, 0xED, 0xF3),
        currentLine: rgb(0xFF, 0xFF, 0xFF, alpha: 0.055),
        gutterBackground: rgb(0x16, 0x1B, 0x22),
        gutterText: rgb(0x8B, 0x94, 0x9E),
        gutterCurrentLine: rgb(0x21, 0x26, 0x2D),
        gutterCurrentLineText: rgb(0x58, 0xA6, 0xFF),
        insertionPoint: rgb(0xE6, 0xED, 0xF3),
        tokenColors: [
            .comment: rgb(0x8B, 0x94, 0x9E),
            .tag: rgb(0x79, 0xC0, 0xFF),
            .attributeName: rgb(0xD2, 0xA8, 0xFF),
            .string: rgb(0xFF, 0xA6, 0x57),
            .command: rgb(0xD2, 0xA8, 0xFF),
            .math: rgb(0x56, 0xD4, 0xDD),
            .argument: rgb(0x79, 0xC0, 0xFF),
            .optionalArgument: rgb(0xFF, 0xA6, 0x57),
            .heading: rgb(0x79, 0xC0, 0xFF),
            .strong: rgb(0xE6, 0xED, 0xF3),
            .code: rgb(0xFF, 0x7B, 0x72),
            .link: rgb(0x58, 0xA6, 0xFF),
            .quote: rgb(0x8B, 0x94, 0x9E),
            .listMarker: rgb(0xFF, 0xA6, 0x57),
        ])

    let baseFont: NSFont
    let boldFont: NSFont

    let backgroundColor: NSColor
    let currentLineColor: NSColor
    let gutterBackgroundColor: NSColor
    let gutterTextColor: NSColor
    let gutterCurrentLineColor: NSColor
    let gutterCurrentLineTextColor: NSColor
    let insertionPointColor: NSColor
    private let textColor: NSColor
    private let tokenColors: [TokenKind: NSColor]

    init(fontSize: CGFloat = 13,
         light: Palette = EditorTheme.light,
         dark: Palette = EditorTheme.dark) {
        baseFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = .monospacedSystemFont(ofSize: fontSize, weight: .bold)

        func adaptive(_ lightColor: NSColor, _ darkColor: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                Self.isDark(appearance) ? darkColor : lightColor
            }
        }

        textColor = adaptive(light.text, dark.text)
        backgroundColor = adaptive(light.background, dark.background)
        currentLineColor = adaptive(light.currentLine, dark.currentLine)
        gutterBackgroundColor = adaptive(light.gutterBackground, dark.gutterBackground)
        gutterTextColor = adaptive(light.gutterText, dark.gutterText)
        gutterCurrentLineColor = adaptive(light.gutterCurrentLine, dark.gutterCurrentLine)
        gutterCurrentLineTextColor = adaptive(light.gutterCurrentLineText,
                                             dark.gutterCurrentLineText)
        insertionPointColor = adaptive(light.insertionPoint, dark.insertionPoint)
        tokenColors = Dictionary(uniqueKeysWithValues: TokenKind.allCases.map { kind in
            (kind, adaptive(light.color(for: kind), dark.color(for: kind)))
        })
    }

    /// The concrete palette used for `appearance`.
    static func palette(for appearance: NSAppearance) -> Palette {
        isDark(appearance) ? dark : light
    }

    /// Attributes applied to all text before token attributes are layered on.
    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: textColor]
    }

    func attributes(for kind: TokenKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .strong:
            return [.font: boldFont]
        case .heading:
            return [.foregroundColor: tokenColors[kind] ?? textColor, .font: boldFont]
        case .link:
            return [.foregroundColor: tokenColors[kind] ?? textColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue]
        default:
            return [.foregroundColor: tokenColors[kind] ?? textColor]
        }
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func rgb(_ red: Int,
                            _ green: Int,
                            _ blue: Int,
                            alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: alpha)
    }
}
