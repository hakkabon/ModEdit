import SwiftUI
import WebKit
import AppKit

/// Live preview of the document, rendered by a format's `PreviewRenderer`.
///
/// Security: the previewed text is untrusted (it is whatever file the user
/// opened), so the web view runs with **JavaScript disabled**, a
/// **non-persistent data store**, and **navigation blocked**. Links open in the
/// default browser instead of replacing the preview.
struct PreviewPane: NSViewRepresentable {
    /// Above this many UTF-16 units the preview refuses to copy and render the
    /// document. Editing large files must not be starved by a debounced render.
    static let maximumSourceLength = 5 * 1_024 * 1_024

    let renderer: any PreviewRenderer
    let revision: UInt64
    let source: @MainActor () -> String?
    /// Caret line the preview should follow, when the format emits source
    /// anchors. `nil` leaves the preview's scroll position alone.
    var scrollRequest: PreviewScrollRequest?
    /// Whether this format's preview HTML carries `data-source-line` anchors.
    /// Untrusted HTML must never be interpreted as source positions.
    var synchronizesScroll = false
    /// Called when the user scrolls the preview to another source block.
    var onScrollToLine: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // No cookies, caches or other state survive between previews.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(
            context.coordinator, name: PreviewScrollBridge.messageHandlerName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.underPageBackgroundColor = .textBackgroundColor
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.track(webView)
        context.coordinator.updateConfiguration(
            synchronizesScroll: synchronizesScroll,
            scrollRequest: scrollRequest,
            onScrollToLine: onScrollToLine)
        context.coordinator.render(revision: revision, source: source,
                                   with: renderer, into: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var task: Task<Void, Never>?
        private var lastHTML: String?
        private var pendingScrollY: Double = 0

        private var synchronizesScroll = false
        private var latestScrollRequest: PreviewScrollRequest?
        private var appliedScrollRequestID: UInt64 = 0
        private var pageReady = false
        private var onScrollToLine: (Int) -> Void = { _ in }

        deinit { task?.cancel() }

        func track(_ webView: WKWebView) {
            activeWebView = webView
        }

        func updateConfiguration(synchronizesScroll: Bool,
                                 scrollRequest: PreviewScrollRequest?,
                                 onScrollToLine: @escaping (Int) -> Void) {
            self.synchronizesScroll = synchronizesScroll
            self.onScrollToLine = onScrollToLine
            if synchronizesScroll {
                latestScrollRequest = scrollRequest
                applyPendingScrollIfReady()
            } else {
                latestScrollRequest = nil
            }
        }

        /// Debounced render. Skips identical output and restores the scroll
        /// position afterwards (reloading used to jump the preview to the top
        /// on every keystroke).
        ///
        /// The source snapshot and all `WKWebView` calls stay on the main
        /// actor; the HTML transformation runs on a detached task so a large
        /// document cannot block typing.
        func render(revision: UInt64,
                    source: @escaping @MainActor () -> String?,
                    with renderer: any PreviewRenderer,
                    into webView: WKWebView) {
            task?.cancel()
            task = Task { [weak self, weak webView] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }

                let html: String
                do {
                    // Materialize the complete document only after the debounce,
                    // not once for every key event. Large documents are not
                    // copied at all; the preview shows a notice instead.
                    guard let text = source() else {
                        html = PreviewPage.wrap(body: """
                            <p>Live preview is disabled for documents larger than \
                            \(PreviewPane.maximumSourceLength / 1_024 / 1_024) MB.</p>
                            """)
                        guard !Task.isCancelled, let self, let webView, html != self.lastHTML else { return }
                        await self.load(html, into: webView)
                        return
                    }
                    html = try await PreviewRendering.renderHTML(from: text, with: renderer)
                } catch {
                    html = PreviewPage.wrap(body: "<pre>\(HTMLEscaping.escape("Preview failed: \(error)"))</pre>")
                }
                guard !Task.isCancelled, let self, let webView, html != self.lastHTML else { return }
                await self.load(html, into: webView)
            }
        }

        private func load(_ html: String, into webView: WKWebView) async {
            lastHTML = html
            pageReady = false
            // A reload discards the installed bridge and the old source-line
            // anchors. Reapply the current caret position once the new page
            // finishes loading.
            appliedScrollRequestID = 0

            // App-injected scripts still work with page JavaScript disabled.
            let value = try? await webView.evaluateJavaScript("window.scrollY")
            pendingScrollY = (value as? Double) ?? 0
            webView.loadHTMLString(html, baseURL: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            if synchronizesScroll {
                // Page JavaScript is disabled, but app-injected scripts run.
                // Install the bridge after every load (the page replaces it),
                // then apply the caret position once the function exists.
                webView.evaluateJavaScript(
                    PreviewScrollBridge.installScript
                ) { [weak self, weak webView] _, _ in
                    guard let self, let webView else { return }
                    Task { @MainActor in
                        self.activeWebView = webView
                        self.applyPendingScrollIfReady()
                    }
                }
                return
            }
            guard pendingScrollY > 0 else { return }
            webView.evaluateJavaScript("window.scrollTo(0, \(pendingScrollY))",
                                       completionHandler: nil)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let action = PreviewNavigationPolicy.action(
                for: navigationAction.request.url,
                isLinkActivated: navigationAction.navigationType == .linkActivated)

            switch action {
            case .allow:
                return .allow
            case .cancel:
                return .cancel
            case .openExternally(let url):
                NSWorkspace.shared.open(url)
                return .cancel
            }
        }

        private func applyPendingScrollIfReady() {
            guard synchronizesScroll,
                  pageReady,
                  let request = latestScrollRequest,
                  request.id != appliedScrollRequestID else { return }
            appliedScrollRequestID = request.id
            // The coordinator does not hold the web view strongly; the
            // navigation delegate receives it for loads, so use the delegate
            // callback's view via the next user scroll instead. The caller
            // stores the web view weakly for this path.
            guard let webView = activeWebView else { return }
            webView.evaluateJavaScript(
                PreviewScrollBridge.scrollScript(toLine: request.line),
                completionHandler: nil)
        }

        /// The most recently updated web view. SwiftUI keeps one representable
        /// per pane; a weak reference avoids retaining a torn-down view.
        private weak var activeWebView: WKWebView?

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard synchronizesScroll,
                  message.name == PreviewScrollBridge.messageHandlerName,
                  let line = PreviewScrollBridge.line(fromMessageBody: message.body)
            else { return }
            onScrollToLine(line)
        }
    }
}
