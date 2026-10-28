import AppKit
import ModEditCore

/// Application entry point.
///
/// All behaviour lives in `ModEditCore`; the app target only starts the
/// document-based AppKit shell so that the core stays a reusable (and testable)
/// library.
@main
struct ModEditApp {
    static func main() {
        ModEditApplication.run()
    }
}
