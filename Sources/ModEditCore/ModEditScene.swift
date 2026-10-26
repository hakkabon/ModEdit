import SwiftUI

/// The document scene of the editor and the **only public entry point** of
/// `ModEditCore`.
///
/// Everything else in the module is internal on purpose: a small public surface
/// keeps the app target honest and leaves the core free to change.
public struct ModEditScene: Scene {
    public init() {}

    public var body: some Scene {
        DocumentGroup(newDocument: { EditorDocument() }) { configuration in
            EditorRootView(document: configuration.document)
        }
    }
}
