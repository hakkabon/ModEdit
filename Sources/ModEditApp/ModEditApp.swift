import SwiftUI
import ModEditCore

@main
struct ModEditApp: App {
    init() {
        FormatRegistry.shared.register(PlainTextFormat())
        FormatRegistry.shared.register(MarkdownFormat())
        FormatRegistry.shared.register(LaTeXFormat())
        FormatRegistry.shared.register(HTMLFormat())
    }

    var body: some Scene {
        DocumentGroup(newDocument: EditorDocument()) { config in
            EditorRootView(document: config.document)
        }
    }
}
