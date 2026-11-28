import WebKit

/// The hardening shared by the live preview and PDF export.
///
/// The previewed text is untrusted. Both web views therefore run without page
/// JavaScript and with a non-persistent data store; the renderers additionally
/// inject a Content-Security-Policy that blocks frames, scripts and remote
/// subresources, and navigation uses `PreviewNavigationPolicy`.
@MainActor
enum PreviewWebViewConfiguration {
    static func make() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // No cookies, caches or other state survive between previews or
        // exports.
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }
}
