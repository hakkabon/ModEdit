import Darwin
import Foundation
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
        #expect(!MarkdownHTML.render("[x](data:text/html,hello)").contains("<a "))
        #expect(MarkdownHTML.render("[x](mailto:user@example.com)")
            .contains("<a href=\"mailto:user@example.com\">x</a>"))
    }

    @Test func linkDestinationsAreNotRewrittenAsEmphasis() {
        let html = MarkdownHTML.render("[docs](https://example.com/a*b*c)")
        #expect(html == "<p><a href=\"https://example.com/a*b*c\">docs</a></p>")
        #expect(!html.contains("<em>"))
    }

    @Test func linkDestinationsMayContainBalancedParentheses() {
        let html = MarkdownHTML.render("[wiki](https://example.com/Foo_(bar))")
        #expect(html == "<p><a href=\"https://example.com/Foo_(bar)\">wiki</a></p>")
    }

    @Test func linkLabelsStillRenderEmphasisAndCode() {
        let html = MarkdownHTML.render("[**bold** and `x*y`](https://example.com)")
        #expect(html.contains("<a href=\"https://example.com\"><strong>bold</strong> and <code>x*y</code></a>"))
    }

    @Test func ampersandsInLinkDestinationsAreEscapedOnce() {
        let html = MarkdownHTML.render("[q](https://example.com/?a=1&b=2)")
        #expect(html.contains("href=\"https://example.com/?a=1&amp;b=2\""))
    }

    @Test func linkSyntaxInsideCodeSpansStaysLiteral() {
        let html = MarkdownHTML.render("`[x](https://a.b)`")
        #expect(html == "<p><code>[x](https://a.b)</code></p>")
        #expect(!html.contains("<a "))
    }

    @Test func windowsLineEndings() {
        let html = MarkdownHTML.render("# A\r\n\r\ntext")
        #expect(html.contains("<h1>A</h1>"))
        #expect(html.contains("<p>text</p>"))
    }
}

@Suite("HTML preview")
struct HTMLPreviewTests {

    @Test func injectsPolicyIntoAnExistingHead() async throws {
        let source = "<!DOCTYPE html><html><head><title>T</title></head><body><p>x</p></body></html>"
        let html = try await HTMLPreviewRenderer().renderHTML(from: source)

        #expect(html.contains("<head><meta http-equiv=\"Content-Security-Policy\""))
        #expect(html.contains("default-src 'none'"))
        #expect(html.contains("form-action 'none'"))
        #expect(html.contains("color-scheme: light dark"))
        #expect(html.contains("<title>T</title>"))
        #expect(html.contains("<p>x</p>"))
    }

    @Test func addsAHeadWhenTheDocumentOnlyHasHTML() async throws {
        let source = "<html><body><p>x</p></body></html>"
        let html = try await HTMLPreviewRenderer().renderHTML(from: source)

        #expect(html.contains("<html><head><meta http-equiv=\"Content-Security-Policy\""))
        #expect(html.contains("<p>x</p>"))
    }

    @Test func preservesADoctypeWhenThereIsNoHTMLOrHeadTag() async throws {
        let source = "<!DOCTYPE html><body><p>x</p></body>"
        let html = try await HTMLPreviewRenderer().renderHTML(from: source)

        #expect(html.hasPrefix("<!DOCTYPE html><meta http-equiv=\"Content-Security-Policy\""))
        #expect(html.contains("<body><p>x</p></body>"))
    }

    @Test func putsPolicyBeforeAFragment() async throws {
        let source = "<p>x</p>"
        let html = try await HTMLPreviewRenderer().renderHTML(from: source)

        #expect(html.hasPrefix("<meta http-equiv=\"Content-Security-Policy\""))
        #expect(html.hasSuffix(source))
    }
}

@Suite("Preview source limit")
struct PreviewSourceLimitTests {

    @Test func previewSnapshotsRefuseDocumentsOverTheLimit() {
        let document = EditorDocument()
        document.setText("12345")

        #expect(document.textLength == 5)
        #expect(document.textSnapshot(upTo: 5) == "12345")
        #expect(document.textSnapshot(upTo: 4) == nil)
    }
}

@Suite("Preview navigation")
struct PreviewNavigationTests {

    @Test func safeLinksOpenExternally() {
        for string in ["https://example.com/a", "http://example.com", "mailto:user@example.com"] {
            let url = URL(string: string)!
            #expect(PreviewNavigationPolicy.action(for: url, isLinkActivated: true)
                == .openExternally(url))
        }
    }

    @Test func unsafeLinksAreCancelled() {
        for string in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hello"] {
            let url = URL(string: string)!
            #expect(PreviewNavigationPolicy.action(for: url, isLinkActivated: true) == .cancel)
        }
    }

    @Test func onlyTheInitialAboutBlankLoadIsAllowed() {
        #expect(PreviewNavigationPolicy.action(for: URL(string: "about:blank"),
                                               isLinkActivated: false) == .allow)
        #expect(PreviewNavigationPolicy.action(for: URL(string: "https://example.com"),
                                               isLinkActivated: false) == .cancel)
        #expect(PreviewNavigationPolicy.action(for: URL(string: "data:text/html,hello"),
                                               isLinkActivated: false) == .cancel)
    }
}

@Suite("Preview rendering")
struct PreviewRenderingTests {

    @MainActor
    @Test func renderersRunOffTheMainActor() async throws {
        let probe = ThreadProbe()
        let html = try await PreviewRendering.renderHTML(
            from: "# Title",
            with: OffMainProbeRenderer(probe: probe))

        #expect(html == "<p># Title</p>")
        #expect(probe.observedMainThread == false)
    }

    @Test func helperProducesTheSameHTMLAsDirectRendering() async throws {
        let direct = try await MarkdownPreviewRenderer().renderHTML(from: "# Title")
        let helper = try await PreviewRendering.renderHTML(from: "# Title",
                                                           with: MarkdownPreviewRenderer())
        #expect(helper == direct)
    }
}

/// Records which thread a renderer observed, without assuming the test runs
/// serially.
private final class ThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThread: Bool?

    func record(isMainThread: Bool) {
        lock.lock()
        mainThread = isMainThread
        lock.unlock()
    }

    var observedMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return mainThread
    }
}

private struct OffMainProbeRenderer: PreviewRenderer {
    let probe: ThreadProbe

    func renderHTML(from source: String) async throws -> String {
        // `Thread.isMainThread` is unavailable in async contexts, so ask the
        // pthread API directly.
        probe.record(isMainThread: pthread_main_np() != 0)
        return "<p>\(HTMLEscaping.escape(source))</p>"
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
