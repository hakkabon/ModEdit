import Foundation

/// Policy for navigations inside the preview web view.
///
/// The preview is untrusted input. The only safe navigation is the initial
/// `loadHTMLString` load, which WebKit reports as an `about:` URL; every other
/// navigation (meta refresh, form submission, frame, scripted redirect) is
/// cancelled. Clicked links never replace the preview: safe links are opened
/// externally instead.
enum PreviewNavigationPolicy {
    enum Action: Equatable {
        /// Let the initial in-memory document load proceed.
        case allow
        /// Keep the current preview in place.
        case cancel
        /// Open the URL in the user's browser or mail client.
        case openExternally(URL)
    }

    static func action(for url: URL?, isLinkActivated: Bool) -> Action {
        if isLinkActivated {
            guard let url,
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme)
            else { return .cancel }
            return .openExternally(url)
        }

        // `loadHTMLString` produces an about:blank document. Anything with a
        // real scheme is a navigation the document attempted on its own.
        guard let url else { return .allow }
        return url.scheme?.lowercased() == "about" ? .allow : .cancel
    }
}
