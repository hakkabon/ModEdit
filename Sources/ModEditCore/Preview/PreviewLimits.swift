import Foundation

/// Size policy shared by the live preview and preview export.
///
/// The cap keeps a debounced preview (or an explicit Export command) from
/// copying and rendering a multi-megabyte document on the main actor. It is a
/// UTF-16 length, matching `NSTextStorage`.
enum PreviewLimits {
    static let maximumSourceLength = 5 * 1_024 * 1_024
}
