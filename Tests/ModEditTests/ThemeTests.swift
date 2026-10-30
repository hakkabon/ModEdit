import Testing
import AppKit
@testable import ModEditCore

@Suite("Editor theme")
struct EditorThemeTests {

    @Test func lightAndDarkPalettesAreDistinct() {
        let light = EditorTheme.palette(for: NSAppearance(named: .aqua)!)
        let dark = EditorTheme.palette(for: NSAppearance(named: .darkAqua)!)

        #expect(light.background != dark.background)
        #expect(light.text != dark.text)
        #expect(light.currentLine != dark.currentLine)
        #expect(light.gutterBackground != dark.gutterBackground)
        for kind in TokenKind.allCases {
            #expect(light.color(for: kind) != dark.color(for: kind),
                    "\(kind) uses the same colour in both appearances")
        }
    }

    @Test func textAndTokenColoursHaveReadableContrast() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let palette = EditorTheme.palette(for: NSAppearance(named: name)!)
            #expect(contrast(palette.text, palette.background) >= 4.5)
            #expect(contrast(palette.gutterText, palette.gutterBackground) >= 4.5)
            #expect(contrast(palette.gutterCurrentLineText,
                             palette.gutterCurrentLine) >= 4.5)
            for kind in TokenKind.allCases {
                #expect(contrast(palette.color(for: kind), palette.background) >= 4.5,
                        "\(kind) has insufficient contrast in \(name.rawValue)")
            }
        }
    }

    @Test func adaptiveColoursResolveToTheCurrentAppearance() {
        let theme = EditorTheme()
        let light = resolved(theme.backgroundColor, for: .aqua)
        let dark = resolved(theme.backgroundColor, for: .darkAqua)

        #expect(light != dark)
        #expect(components(light) == components(EditorTheme.light.background))
        #expect(components(dark) == components(EditorTheme.dark.background))
        #expect(resolved(theme.currentLineColor, for: .darkAqua)
                != resolved(theme.currentLineColor, for: .aqua))
    }

    private func resolved(_ color: NSColor, for name: NSAppearance.Name) -> NSColor {
        let appearance = NSAppearance(named: name)!
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    private func components(_ color: NSColor) -> [CGFloat] {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
    }

    private func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        let firstLuminance = luminance(first)
        let secondLuminance = luminance(second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ color: NSColor) -> Double {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }
}
