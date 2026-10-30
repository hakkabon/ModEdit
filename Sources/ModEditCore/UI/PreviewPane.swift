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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // No cookies, caches or other state survive between previews.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.underPageBackgroundColor = .textBackgroundColor
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.render(revision: revision, source: source,
                                   with: renderer, into: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var task: Task<Void, Never>?
        private var lastHTML: String?
        private var pendingScrollY: Double = 0

        deinit { task?.cancel() }

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
                        self.lastHTML = html
                        webView.loadHTMLString(html, baseURL: nil)
                        return
                    }
                    html = try await PreviewRendering.renderHTML(from: text, with: renderer)
                } catch {
                    html = PreviewPage.wrap(body: "<pre>\(HTMLEscaping.escape("Preview failed: \(error)"))</pre>")
                }
                guard !Task.isCancelled, let self, let webView, html != self.lastHTML else { return }
                self.lastHTML = html

                // App-injected scripts still work with page JavaScript disabled.
                let value = try? await webView.evaluateJavaScript("window.scrollY")
                self.pendingScrollY = (value as? Double) ?? 0
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard pendingScrollY > 0 else { return }
            webView.evaluateJavaScript("window.scrollTo(0, \(pendingScrollY))", completionHandler: nil)
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
    }
}
