import SwiftUI
import ModEditCore

/// Application entry point.
///
/// All behaviour lives in `ModEditCore`; the app target only hosts the scene so
/// that the core stays a reusable (and testable) library.
@main
struct ModEditApp: App {
    var body: some Scene {
        ModEditScene()
    }
}
