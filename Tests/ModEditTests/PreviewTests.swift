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

@Suite("Preview page")
struct PreviewPageTests {

    @Test func localResourcesAreAllowedWithoutRemoteLoads() {
        let policy = PreviewPage.contentSecurityPolicy
        #expect(policy.contains("script-src 'none'"))
        #expect(policy.contains("style-src 'unsafe-inline' file:"))
        #expect(policy.contains("img-src data: file:"))
        #expect(policy.contains("font-src data: file:"))
        #expect(policy.contains("media-src data: file:"))
        #expect(policy.contains("connect-src 'none'"))
        #expect(policy.contains("frame-src 'none'"))
        #expect(policy.contains("base-uri 'none'"))
        #expect(!policy.contains("http:"))
        #expect(!policy.contains("https:"))
    }

    @Test func imagesFitThePreviewWidth() {
        let html = PreviewPage.wrap(body: "<p>x</p>")
        #expect(html.contains("img { max-width: 100%; height: auto; }"))
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

    @Test func sourceAnchorsTrackOneBasedBlockLines() {
        let source = """
            # A

            text

            - one
            - two

            ```
            code
            ```
            """
        let html = MarkdownHTML.render(source, sourceAnchors: true)

        #expect(html.contains("<h1 data-source-line=\"1\">A</h1>"))
        #expect(html.contains("<p data-source-line=\"3\">text</p>"))
        #expect(html.contains("<ul data-source-line=\"5\">"))
        #expect(html.contains("<li data-source-line=\"5\">one</li>"))
        #expect(html.contains("<li data-source-line=\"6\">two</li>"))
        #expect(html.contains("<pre data-source-line=\"8\"><code>code</code></pre>"))
    }

    @Test func sourceAnchorsCanBeOmitted() {
        let html = MarkdownHTML.render("# A\n\ntext")
        #expect(!html.contains("data-source-line"))
    }

    @Test func sharedProjectionAddsSetextHeadings() {
        let html = MarkdownHTML.render("Title\n=====\n\nSub\n---")
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<h2>Sub</h2>"))
    }

    @Test func sharedProjectionAddsTables() {
        let html = MarkdownHTML.render("| a | b |\n|---|---|\n| 1 | 2 |")
        #expect(html.contains("<table>"))
        #expect(html.contains("<thead><tr><th>a</th><th>b</th></tr></thead>"))
        #expect(html.contains("<tr><td>1</td><td>2</td></tr>"))
        #expect(!html.contains("---"))
    }

    @Test func sharedProjectionAddsNestedLists() {
        let html = MarkdownHTML.render("- one\n  - nested\n- two")
        #expect(html.contains("<li>one\n<ul>\n<li>nested</li>\n</ul></li>"))
        #expect(html.contains("<li>two</li>"))
    }

    @Test func sharedProjectionAddsListsInsideBlockQuotes() {
        let onlyList = MarkdownHTML.render("> - one\n> - two")
        #expect(onlyList == "<blockquote>\n<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n</blockquote>")

        let withProse = MarkdownHTML.render("> intro\n>\n> - one\n>   - nested")
        #expect(withProse.contains("<p>intro</p>"))
        #expect(withProse.contains("<li>one\n<ul>\n<li>nested</li>\n</ul></li>"))
    }

    @Test func escapedPipesStayInsideASingleCell() {
        let html = MarkdownHTML.render("| a | b |\n|---|---|\n| 1 | \\| |")
        #expect(html.contains("<tr><td>1</td><td>|</td></tr>"))
        #expect(!html.contains("<td></td>"))
    }

    @Test func sharedProjectionAddsStrikethroughAndTaskLists() {
        let html = MarkdownHTML.render("~~gone~~\n\n- [ ] todo\n- [x] done")
        #expect(html.contains("<del>gone</del>"))
        #expect(html.contains("<input type=\"checkbox\" disabled> todo"))
        #expect(html.contains("<input type=\"checkbox\" disabled checked> done"))
    }

    @Test func orderedListsKeepANonDefaultStart() {
        let html = MarkdownHTML.render("3. three\n4. four")
        #expect(html.contains("<ol start=\"3\">"))
    }

    @Test func hardBreaksBecomeLineBreaks() {
        let html = MarkdownHTML.render("line  \nbreak")
        #expect(html.contains("line<br>break"))
    }

    @Test func sourceAnchorsCoverListsTablesAndQuotes() {
        let source = """
            > quote

            | a | b |
            |---|---|
            | 1 | 2 |

            3. three
            4. four
            """
        let html = MarkdownHTML.render(source, sourceAnchors: true)

        #expect(html.contains("<blockquote data-source-line=\"1\">"))
        #expect(html.contains("<table data-source-line=\"3\">"))
        #expect(html.contains("<ol data-source-line=\"7\" start=\"3\">"))
        #expect(html.contains("<li data-source-line=\"7\">three</li>"))
        #expect(html.contains("<li data-source-line=\"8\">four</li>"))
    }

    @Test func unresolvedImagesKeepAltTextAndUnsafeLinksStayText() {
        let html = MarkdownHTML.render("[x](javascript:alert(1)) ![alt](pic.png)")
        #expect(!html.contains("<a "))
        #expect(!html.contains("<img "))
        #expect(html.contains("x alt"))
    }

    @Test func relativeImagesNeedADocumentDirectory() {
        let source = "![alt](pic.png)"
        let without = MarkdownHTML.render(source)
        #expect(!without.contains("<img "))
        #expect(without.contains("alt"))

        let with = MarkdownHTML.render(
            source, baseURL: URL(fileURLWithPath: "/tmp/docs", isDirectory: true))
        #expect(with == "<p><img src=\"pic.png\" alt=\"alt\"></p>")
    }

    @Test func absoluteAndLocalFileImagesNeedADocumentDirectory() {
        for destination in ["/tmp/pic.png", "file:///tmp/pic.png"] {
            let source = "![alt](\(destination))"
            #expect(!MarkdownHTML.render(source).contains("<img "))

            let html = MarkdownHTML.render(
                source, baseURL: URL(fileURLWithPath: "/tmp/docs", isDirectory: true))
            #expect(html.contains("<img src=\"\(destination)\" alt=\"alt\">"))
        }
    }

    @Test func formattedAltTextBecomesOneImage() {
        let html = MarkdownHTML.render(
            "![a **b** and `code`](pic.png)",
            baseURL: URL(fileURLWithPath: "/tmp/docs", isDirectory: true))

        #expect(html == "<p><img src=\"pic.png\" alt=\"a b and code\"></p>")
    }

    @Test func adjacentImagesWithTheSameDestinationStaySeparate() {
        let html = MarkdownHTML.render(
            "![a](pic.png)![b](pic.png)",
            baseURL: URL(fileURLWithPath: "/tmp/docs", isDirectory: true))

        #expect(html == "<p><img src=\"pic.png\" alt=\"a\"><img src=\"pic.png\" alt=\"b\"></p>")
    }

    @Test func emptyAltTextStaysEmpty() {
        let html = MarkdownHTML.render(
            "![](pic.png)",
            baseURL: URL(fileURLWithPath: "/tmp/docs", isDirectory: true))

        #expect(html == "<p><img src=\"pic.png\" alt=\"\"></p>")
    }

    @Test func dataImagesWorkWithoutADocumentDirectory() {
        let source = "![alt](data:image/png;base64,AAAA)"
        let html = MarkdownHTML.render(source)

        #expect(html == "<p><img src=\"data:image/png;base64,AAAA\" alt=\"alt\"></p>")
    }

    @Test func remoteAndUnsafeImageDestinationsStayAltText() {
        let baseURL = URL(fileURLWithPath: "/tmp/docs", isDirectory: true)
        for destination in [
            "https://example.com/pic.png",
            "//example.com/pic.png",
            "javascript:alert(1)",
            "data:text/html,hello",
            "file://remotehost/pic.png",
        ] {
            let html = MarkdownHTML.render("![alt](\(destination))", baseURL: baseURL)
            #expect(!html.contains("<img "), "unexpected image for \(destination)")
            #expect(html.contains("alt"))
        }
    }

    @Test func imageDestinationsAreEscapedOnce() {
        let html = MarkdownHTML.render(
            "![alt](pic.png?a=1&b=2)",
            baseURL: URL(fileURLWithPath: "/tmp/docs", isDirectory: true))

        #expect(html.contains("src=\"pic.png?a=1&amp;b=2\""))
        #expect(!html.contains("&amp;amp;"))
    }
}

@Suite("Preview scroll bridge")
struct PreviewScrollBridgeTests {

    @Test func markdownPreviewsOptIntoSourceMapping() {
        #expect(MarkdownFormat().supportsPreviewSourceMapping)
        #expect(!HTMLFormat().supportsPreviewSourceMapping)
        #expect(!LaTeXFormat().supportsPreviewSourceMapping)
    }

    @Test func installScriptReportsScrollsAndDefinesTheScrollFunction() {
        let script = PreviewScrollBridge.installScript
        #expect(script.contains("data-source-line"))
        #expect(script.contains(PreviewScrollBridge.messageHandlerName))
        #expect(script.contains("window.modEditScrollToLine"))
        #expect(script.contains("suppress"))
    }

    @Test func scrollScriptClampsToTheFirstLine() {
        #expect(PreviewScrollBridge.scrollScript(toLine: 0)
            .contains("modEditScrollToLine(1)"))
        #expect(PreviewScrollBridge.scrollScript(toLine: 42)
            .contains("modEditScrollToLine(42)"))
    }

    @Test func messageBodiesDecodeIntegersAndNumbers() {
        #expect(PreviewScrollBridge.line(fromMessageBody: ["line": 7]) == 7)
        #expect(PreviewScrollBridge.line(fromMessageBody: ["line": NSNumber(value: 9)]) == 9)
        #expect(PreviewScrollBridge.line(fromMessageBody: ["other": 7]) == nil)
        #expect(PreviewScrollBridge.line(fromMessageBody: "7") == nil)
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

    @Test func markdownPreviewUsesTheSharedProjection() async throws {
        let source = """
            Title
            =====

            | a | b |
            |---|---|
            | 1 | 2 |
            """
        let html = try await MarkdownPreviewRenderer().renderHTML(from: source)

        #expect(html.contains("<h1 data-source-line=\"1\">Title</h1>"))
        #expect(html.contains("<table data-source-line=\"4\">"))
        #expect(html.contains("<th>a</th><th>b</th>"))
    }

    @Test func helperForwardsTheDocumentDirectory() async throws {
        let baseURL = URL(fileURLWithPath: "/tmp/docs", isDirectory: true)
        let probe = BaseURLProbe()

        _ = try await PreviewRendering.renderHTML(
            from: "x", baseURL: baseURL, with: BaseURLProbeRenderer(probe: probe))

        #expect(probe.observedBaseURL == baseURL)
    }

    @Test func markdownPreviewResolvesImagesThroughTheDocumentDirectory() async throws {
        let baseURL = URL(fileURLWithPath: "/tmp/docs", isDirectory: true)
        let html = try await MarkdownPreviewRenderer().renderHTML(
            from: "![alt](pic.png)", baseURL: baseURL)

        #expect(html.contains("<img src=\"pic.png\" alt=\"alt\">"))
        #expect(html.contains("img-src data: file:"))
    }

    @Test func renderersUseTheBaseURLLessDefault() async throws {
        let html = try await HTMLPreviewRenderer().renderHTML(
            from: "<p>x</p>", baseURL: URL(fileURLWithPath: "/tmp/docs"))

        #expect(html.contains("<p>x</p>"))
        #expect(!html.contains("file:///tmp/docs"))
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

/// Records the document directory a renderer received.
private final class BaseURLProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var baseURL: URL?

    func record(_ url: URL?) {
        lock.lock()
        baseURL = url
        lock.unlock()
    }

    var observedBaseURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return baseURL
    }
}

private struct BaseURLProbeRenderer: PreviewRenderer {
    let probe: BaseURLProbe

    func renderHTML(from source: String) async throws -> String {
        "<p>default</p>"
    }

    func renderHTML(from source: String, baseURL: URL?) async throws -> String {
        probe.record(baseURL)
        return "<p>\(baseURL?.lastPathComponent ?? "none")</p>"
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
