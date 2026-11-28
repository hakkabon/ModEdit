import AppKit

/// Switches the editor between soft-wrapped and horizontally scrolling layout.
///
/// Both modes keep the same text storage and selection. Only the text
/// container's width policy and the scroll view's horizontal scroller change.
@MainActor
enum EditorSoftWrap {

    static func apply(_ enabled: Bool,
                      to textView: NSTextView,
                      in scrollView: NSScrollView) {
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        if enabled {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            let width = scrollView.contentSize.width > 0
                ? scrollView.contentSize.width
                : textView.bounds.width
            textView.textContainer?.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = false
        } else {
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = true
        }

        textView.needsLayout = true
        textView.needsDisplay = true
    }
}
