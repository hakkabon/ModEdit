import AppKit
import WebKit

/// Renders preview HTML to PDF in an offscreen web view.
///
/// Security matches the live preview: page JavaScript is disabled, the data
/// store is non-persistent, and non-initial navigations are cancelled. The
/// incoming HTML is always produced by a `PreviewRenderer`, so generated pages
/// carry the escaped body and user HTML carries the injected
/// Content-Security-Policy that blocks scripts, frames and remote subresources.
///
/// WebKit's `createPDF` captures the complete rendered page as one continuous
/// PDF page. That preserves code blocks and tables without splitting a line
/// across printer pages.
@MainActor
final class PreviewPDFExporter: NSObject, WKNavigationDelegate, PreviewPDFExporting {
    /// US Letter width at 72 dpi. Height controls the initial layout viewport;
    /// the generated PDF grows to the document's rendered height.
    private static let pageSize = NSSize(width: 612, height: 792)

    private var loadContinuation: CheckedContinuation<Void, any Error>?

    func pdfData(from html: String, baseURL: URL?) async throws -> Data {
        let configuration = PreviewWebViewConfiguration.make()

        let webView = WKWebView(
            frame: NSRect(origin: .zero, size: Self.pageSize),
            configuration: configuration)
        webView.navigationDelegate = self

        try await load(html, baseURL: baseURL, into: webView)
        // The navigation callback fires before local images and fonts have
        // necessarily painted. A short settle avoids exporting placeholders.
        try await Task.sleep(for: .milliseconds(100))
        return try await createPDF(from: webView)
    }

    private func load(_ html: String,
                      baseURL: URL?,
                      into webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    private func createPDF(from webView: WKWebView) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func finishLoading(_ result: Result<Void, any Error>) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(.success(()))
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: any Error) {
        finishLoading(.failure(error))
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        finishLoading(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoading(.failure(PreviewExportError.webContentTerminated))
    }

    /// The live preview never lets the page navigate away from the loaded
    /// document. Export uses the same policy and never opens links externally.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        switch PreviewNavigationPolicy.action(
            for: navigationAction.request.url,
            isLinkActivated: navigationAction.navigationType == .linkActivated) {
        case .allow:
            return .allow
        case .cancel, .openExternally:
            return .cancel
        }
    }
}
