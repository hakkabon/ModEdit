import Testing
@testable import ModEditCore

@Suite("HTMLEscaping")
struct HTMLEscapingTests {
    @Test func escapesAllSpecialCharacters() {
        #expect(HTMLEscaping.escape("a<b>&\"'") == "a&lt;b&gt;&amp;&quot;&#39;")
    }
}

@Suite("MarkdownHTML")
struct MarkdownHTMLTests {

    @Test func headings() {
        #expect(MarkdownHTML.render("# Title").contains("<h1>Title</h1>"))
        #expect(MarkdownHTML.render("### Deep").contains("<h3>Deep</h3>"))
    }

    @Test func hashInsideAWordIsNotAHeading() {
        let html = MarkdownHTML.render("C# (language)")
        #expect(!html.contains("<h1>"))
        #expect(html.contains("<p>C# (language)</p>"))
    }

    @Test func emphasis() {
        let html = MarkdownHTML.render("**bold** and *it*")
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>it</em>"))
    }

    @Test func spacedAsterisksAreLiteral() {
        #expect(MarkdownHTML.render("2 * 3 * 4").contains("2 * 3 * 4"))
    }

    @Test func codeSpansAreNotReinterpreted() {
        let html = MarkdownHTML.render("`*x*`")
        #expect(html.contains("<code>*x*</code>"))
        #expect(!html.contains("<em>"))
    }

    @Test func rawHTMLIsEscaped() {
        let html = MarkdownHTML.render("<script>alert(1)</script>")
        #expect(html.contains("&lt;script&gt;"))
        #expect(!html.contains("<script>"))
    }

    @Test func listsAndParagraphs() {
        let html = MarkdownHTML.render("- a\n- b\n\ntext")
        #expect(html == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n<p>text</p>")
    }

    @Test func fencedCodeIsEscapedVerbatim() {
        let html = MarkdownHTML.render("```\n<b>\n```")
        #expect(html == "<pre><code>&lt;b&gt;</code></pre>")
    }

    @Test func blockQuote() {
        #expect(MarkdownHTML.render("> hi").contains("<blockquote>hi</blockquote>"))
    }

    @Test func onlySafeLinkSchemesBecomeLinks() {
        #expect(MarkdownHTML.render("[x](https://a.b)").contains("<a href=\"https://a.b\">x</a>"))
        #expect(!MarkdownHTML.render("[x](javascript:alert(1))").contains("<a "))
    }

    @Test func windowsLineEndings() {
        let html = MarkdownHTML.render("# A\r\n\r\ntext")
        #expect(html.contains("<h1>A</h1>"))
        #expect(html.contains("<p>text</p>"))
    }
}

@Suite("LaTeXHTML")
struct LaTeXHTMLTests {

    @Test func mathSymbolsAndScripts() {
        let html = LaTeXHTML.render("Let $\\alpha^2$.")
        #expect(html.contains("α<sup>2</sup>"))
    }

    @Test func braceScripts() {
        let html = LaTeXHTML.render("$\\sum_{i=1}^{n} x_i$")
        #expect(html.contains("∑<sub>i=1</sub><sup>n</sup>"))
        #expect(html.contains("x<sub>i</sub>"))
    }

    @Test func commentsAreStripped() {
        let html = LaTeXHTML.render("visible % hidden")
        #expect(html.contains("visible"))
        #expect(!html.contains("hidden"))
    }

    @Test func sourceIsEscaped() {
        let html = LaTeXHTML.render("<script>alert(1)</script>")
        #expect(html.contains("&lt;script&gt;"))
        #expect(!html.contains("<script>"))
    }

    @Test func sectionsAndTextStyles() {
        let html = LaTeXHTML.render("\\section{Intro}\nSome \\textbf{bold} text.")
        #expect(html.contains("<h2>Intro</h2>"))
        #expect(html.contains("<strong>bold</strong>"))
    }

    @Test func onlyTheDocumentBodyIsShown() {
        let html = LaTeXHTML.render("\\documentclass{article}\n\\begin{document}\nHello\n\\end{document}")
        #expect(html.contains("Hello"))
        #expect(!html.contains("documentclass"))
    }
}
