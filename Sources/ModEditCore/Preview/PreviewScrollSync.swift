import Foundation

/// A request to bring the caret's source line into view in the live preview.
///
/// The identifier makes repeated requests for the same line distinguishable,
/// so clicking on a line that is already current still re-centres the preview.
struct PreviewScrollRequest: Equatable, Sendable {
    let id: UInt64
    /// One-based source line, matching the status bar and gutter.
    let line: Int
}

/// A request from the preview to scroll the source editor to a source line.
///
/// Scrolling must not move the caret: the user is browsing the preview, not
/// editing the document. The editor only reveals the line.
struct EditorScrollRequest: Equatable, Sendable {
    let id: UInt64
    /// One-based source line, matching the status bar and gutter.
    let line: Int
}

/// The JavaScript bridge shared by the preview page and the native pane.
///
/// Page JavaScript is disabled, but scripts injected by the app still run (the
/// preview already uses `evaluateJavaScript` to restore its scroll position).
/// The bridge therefore installs one scroll listener after each load and
/// posts debounced line numbers through a `WKScriptMessageHandler`.
enum PreviewScrollBridge {
    static let messageHandlerName = "modEditPreviewScroll"

    /// Installs `window.modEditScrollToLine(line)` and reports user scrolling.
    ///
    /// Programmatic scrolls are suppressed so following the caret cannot feed
    /// back into an editor scroll request. The reported line is the last anchor
    /// at or above the viewport top, which is the block currently being read.
    static let installScript = """
        (function() {
            if (window.__modEditScrollBridge) { return; }
            window.__modEditScrollBridge = true;
            var suppress = false;
            var lastSent = -1;
            var timer = null;

            function anchors() {
                return document.querySelectorAll('[data-source-line]');
            }

            function lineAtViewportTop() {
                var nodes = anchors();
                if (!nodes.length) { return null; }
                var top = window.scrollY + 1;
                var best = nodes[0];
                for (var i = 0; i < nodes.length; i++) {
                    var rect = nodes[i].getBoundingClientRect();
                    if (rect.top + window.scrollY <= top) {
                        best = nodes[i];
                    } else {
                        break;
                    }
                }
                var line = parseInt(best.getAttribute('data-source-line'), 10);
                return isNaN(line) ? null : line;
            }

            function report() {
                if (suppress) { return; }
                var line = lineAtViewportTop();
                if (line === null || line === lastSent) { return; }
                lastSent = line;
                try {
                    window.webkit.messageHandlers.\(messageHandlerName)
                        .postMessage({ line: line });
                } catch (error) {}
            }

            window.addEventListener('scroll', function() {
                if (suppress) { return; }
                if (timer) { clearTimeout(timer); }
                timer = setTimeout(report, 80);
            }, { passive: true });

            window.modEditScrollToLine = function(line) {
                var nodes = anchors();
                if (!nodes.length) { return; }
                var target = nodes[0];
                var targetLine = parseInt(target.getAttribute('data-source-line'), 10);
                for (var i = 0; i < nodes.length; i++) {
                    var value = parseInt(nodes[i].getAttribute('data-source-line'), 10);
                    if (value <= line) {
                        target = nodes[i];
                        targetLine = value;
                    } else {
                        break;
                    }
                }
                var top = target.getBoundingClientRect().top + window.scrollY - 8;
                suppress = true;
                lastSent = targetLine;
                window.scrollTo(0, Math.max(0, top));
                setTimeout(function() { suppress = false; }, 150);
            };
        })();
        """

    /// Moves the preview to the anchor at or above `line`, or leaves it alone
    /// when the page has no anchors (an HTML or LaTeX preview, for example).
    static func scrollScript(toLine line: Int) -> String {
        "window.modEditScrollToLine ? window.modEditScrollToLine(\(max(1, line))) : 0;"
    }

    /// Extracts the line number from a message body posted by `installScript`.
    static func line(fromMessageBody body: Any) -> Int? {
        guard let dictionary = body as? [String: Any] else { return nil }
        if let line = dictionary["line"] as? Int { return line }
        if let number = dictionary["line"] as? NSNumber { return number.intValue }
        return nil
    }
}
