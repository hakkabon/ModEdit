import AppKit

/// Maps semantic `TokenKind`s to fonts and colours.
///
/// Uses dynamic system colours, so light/dark mode works without extra code.
struct EditorTheme {
    let baseFont: NSFont
    let boldFont: NSFont

    init(fontSize: CGFloat = 13) {
        baseFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = .monospacedSystemFont(ofSize: fontSize, weight: .bold)
    }

    /// Attributes applied to all text before token attributes are layered on.
    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.textColor]
    }

    func attributes(for kind: TokenKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .comment, .quote:
            return [.foregroundColor: NSColor.secondaryLabelColor]
        case .tag, .argument:
            return [.foregroundColor: NSColor.systemBlue]
        case .attributeName, .command:
            return [.foregroundColor: NSColor.systemPurple]
        case .string, .optionalArgument, .listMarker:
            return [.foregroundColor: NSColor.systemOrange]
        case .math:
            return [.foregroundColor: NSColor.systemTeal]
        case .heading:
            return [.foregroundColor: NSColor.systemBlue, .font: boldFont]
        case .strong:
            return [.font: boldFont]
        case .code:
            return [.foregroundColor: NSColor.systemPink]
        case .link:
            return [.foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue]
        }
    }
}
