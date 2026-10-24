import SwiftUI
import WebKit

struct PreviewPane: NSViewRepresentable {
    let renderer: any PreviewRenderer
    let source: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView { WKWebView() }
    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.render(source, with: renderer, into: webView)
    }

    @MainActor final class Coordinator {
        private var task: Task<Void, Never>?
        func render(_ source: String, with renderer: any PreviewRenderer, into webView: WKWebView) {
            task?.cancel()
            task = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                guard let html = try? await renderer.renderHTML(from: source) else { return }
                webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }
}
